#!/usr/bin/env bash
# Publish the samples into GitLab, and wire GitLab up as a Dev Spaces SCM
# provider so devfiles resolve from it.
#
# Unlike the Gitea attempt, GitLab is a provider Dev Spaces actually supports
# (checluster.spec.gitServices.gitlab), which is the whole reason for the swap.
#
# Pushes straight from your working tree. Re-run any time you change a sample.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require git; require curl; require_login

BASE="https://${GITLAB_HOST}"
CURL="curl -fsSk"

banner "Seeding ${BASE}"

# --- credentials ------------------------------------------------------------
info "reading the initial root password"
ROOT_PASSWORD="$(oc get secret gitlab-gitlab-initial-root-password \
  -n "${GITLAB_NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
[[ -n "${ROOT_PASSWORD}" ]] || die "could not read the root password secret.
    Is GitLab finished reconciling? oc get gitlab -n ${GITLAB_NAMESPACE}"

# The API needs a token, and a token can only be minted from inside GitLab.
# The toolbox pod ships a rails console for exactly this kind of bootstrap.
info "minting an API token via the toolbox pod"
TOOLBOX="$(oc get pods -n "${GITLAB_NAMESPACE}" -l app=toolbox -o name | head -1)"
[[ -n "${TOOLBOX}" ]] || die "toolbox pod not found. Has GitLab finished starting?"

TOKEN="$(oc exec -n "${GITLAB_NAMESPACE}" "${TOOLBOX}" -- \
  gitlab-rails runner "
    u = User.find_by_username('root')
    t = u.personal_access_tokens.find_by(name: 'demo-seed') ||
        u.personal_access_tokens.create!(
          name: 'demo-seed',
          scopes: ['api','write_repository'],
          expires_at: 90.days.from_now)
    t.set_token('DEMO_SEED_TOKEN_PLACEHOLDER_VALUE') if t.token.blank?
    t.save!
    puts t.token
  " 2>/dev/null | tail -1 | tr -d '\r')"

[[ -n "${TOKEN}" ]] || die "could not mint an API token.
    Try manually: oc exec -n ${GITLAB_NAMESPACE} ${TOOLBOX} -- gitlab-rails console"

API="${BASE}/api/v4"
AUTH="-H PRIVATE-TOKEN:${TOKEN}"

# --- group and projects -----------------------------------------------------
info "ensuring group ${GITLAB_GROUP}"
${CURL} ${AUTH} -X POST "${API}/groups" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${GITLAB_GROUP}\",\"path\":\"${GITLAB_GROUP}\",\"visibility\":\"public\"}" \
  >/dev/null 2>&1 || info "  group exists already"

GROUP_ID="$(${CURL} ${AUTH} "${API}/groups/${GITLAB_GROUP}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

publish() {
  local name="$1"
  local src="${REPO_ROOT}/samples/${name}"
  [[ -d "${src}" ]] || die "sample not found: ${src}"

  info "publishing ${name}"
  ${CURL} ${AUTH} -X POST "${API}/projects" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${name}\",\"path\":\"${name}\",\"namespace_id\":${GROUP_ID},\"visibility\":\"public\",\"initialize_with_readme\":false}" \
    >/dev/null 2>&1 || info "  project exists already"

  rm -rf "${WORK}/${name}"
  cp -r "${src}" "${WORK}/${name}"
  cd "${WORK}/${name}"

  # Render the AI endpoint. Done at publish time rather than committed to the
  # source repo, because the endpoint is environment state.
  if [[ -f devfile.yaml ]]; then
    sed -i.bak \
      -e "s|AI_BASE_URL_PLACEHOLDER|${AI_BASE_URL:-}|g" \
      -e "s|AI_MODEL_PLACEHOLDER|${AI_MODEL:-}|g" \
      devfile.yaml && rm -f devfile.yaml.bak
  fi

  git init -q -b main
  git config user.email "platform@example.internal"
  git config user.name "Platform Engineering"
  git config http.sslVerify false
  git add -A
  git commit -q -m "Approved stack, published by platform engineering"
  git remote add origin "https://root:${TOKEN}@${GITLAB_HOST}/${GITLAB_GROUP}/${name}.git"
  git push -q -u origin main --force
  cd "${REPO_ROOT}"
}

publish payments-service
publish ansible-automation
publish ledger-service

# --- Dev Spaces SCM provider ------------------------------------------------
# This is the part Gitea could not do. Dev Spaces needs an OAuth application
# registered in GitLab so it can fetch devfiles and, later, act on the
# developer's behalf.
banner "Registering Dev Spaces as an OAuth application"

CALLBACK="https://devspaces.${CLUSTER_APPS_DOMAIN}/api/oauth/callback"
info "callback: ${CALLBACK}"

OAUTH_JSON="$(${CURL} ${AUTH} -X POST "${API}/applications" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"devspaces\",\"redirect_uri\":\"${CALLBACK}\",\"scopes\":\"api write_repository openid\"}" 2>/dev/null || true)"

if [[ -n "${OAUTH_JSON}" ]]; then
  APP_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["application_id"])' <<< "${OAUTH_JSON}")"
  APP_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])' <<< "${OAUTH_JSON}")"

  oc create secret generic gitlab-oauth-config \
    -n "${DEVSPACES_NAMESPACE}" \
    --from-literal=id="${APP_ID}" \
    --from-literal=secret="${APP_SECRET}" \
    --dry-run=client -o yaml | oc apply -f -

  oc label secret gitlab-oauth-config -n "${DEVSPACES_NAMESPACE}" \
    app.kubernetes.io/part-of=che.eclipse.org \
    app.kubernetes.io/component=oauth-scm-configuration --overwrite
  oc annotate secret gitlab-oauth-config -n "${DEVSPACES_NAMESPACE}" \
    che.eclipse.org/oauth-scm-server=gitlab \
    che.eclipse.org/scm-server-endpoint="${BASE}" --overwrite

  info "patching the CheCluster to register GitLab"
  oc patch checluster devspaces -n "${DEVSPACES_NAMESPACE}" --type merge -p "$(cat <<JSON
{"spec":{"gitServices":{"gitlab":[{"endpoint":"${BASE}","secretName":"gitlab-oauth-config"}]}}}
JSON
)"
else
  warn "OAuth application registration failed or already exists."
  warn "If workspaces cannot resolve devfiles, register it by hand at"
  warn "  ${BASE}/admin/applications"
  warn "with callback ${CALLBACK} and scopes: api, write_repository, openid"
fi

banner "Seeded"
cat <<MSG

    Create workspaces from these URLs:

      ${BASE}/${GITLAB_GROUP}/payments-service      acts 2 to 4
      ${BASE}/${GITLAB_GROUP}/ansible-automation    act 6
      ${BASE}/${GITLAB_GROUP}/ledger-service        act 5, no devfile on purpose

    GitLab UI: ${BASE}   (root / see the secret below)
      oc get secret gitlab-gitlab-initial-root-password -n ${GITLAB_NAMESPACE} \\
        -o jsonpath='{.data.password}' | base64 -d

MSG

#!/usr/bin/env bash
# Publish the samples into GitLab, and register GitLab as a Dev Spaces SCM
# provider so workspaces can resolve devfiles from it.
#
# GitLab is one of the four providers Dev Spaces actually supports
# (checluster.spec.gitServices: azure, bitbucket, github, gitlab). That is the
# whole reason for using it: Dev Spaces cannot resolve a devfile from an
# unrecognised provider, which is where the Gitea attempt died.
#
# Pushes straight from your working tree. Re-run any time you change a sample:
# it force-pushes, so the projects always match your tree.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require git; require curl; require_login
assert_provisioned_cluster

BASE="https://${GITLAB_HOST}"

# -f matters. Without it curl exits 0 on a 401, so an auth failure sails past
# the checks below and surfaces later as a confusing "repository not found".
# -k because the Route uses the cluster's default certificate.
CURL=(curl -fsSk)

banner "Seeding ${BASE}"

# --- token ------------------------------------------------------------------
# Two sources. Prefer one supplied in the environment: it removes any dependency
# on the toolbox pod, which exists for backups and rails access and is not
# otherwise needed by this demo.
#
#   Mint one at ${BASE}/-/user_settings/personal_access_tokens
#   Scopes: api, write_repository
#   Then:   export GITLAB_TOKEN=<token> && ./scripts/seed-gitlab.sh
if [[ -n "${GITLAB_TOKEN:-}" ]]; then
  info "using GITLAB_TOKEN from the environment"
  TOKEN="${GITLAB_TOKEN}"
else
  info "no GITLAB_TOKEN set, trying the toolbox pod"
  TOOLBOX="$(oc get pods -n "${GITLAB_NAMESPACE}" -l app=toolbox \
    --field-selector=status.phase=Running -o name 2>/dev/null | head -1)"

  [[ -n "${TOOLBOX}" ]] || die "no running toolbox pod, and GITLAB_TOKEN is not set.

    Mint a token in the UI instead:
      ${BASE}/-/user_settings/personal_access_tokens
      scopes: api, write_repository

    Root password:
      oc get secret gitlab-gitlab-initial-root-password -n ${GITLAB_NAMESPACE} \\
        -o jsonpath='{.data.password}' | base64 -d

    Then: export GITLAB_TOKEN=<token> && ./scripts/seed-gitlab.sh"

  # TIMEOUT IS LOAD-BEARING. Rails takes a minute or two to boot on the toolbox
  # pod, and without a bound this exec hangs, taking up.sh down with it. That is
  # a silent stall with no output, which is the worst kind.
  info "minting an API token via the toolbox (Rails is slow to boot, allow 3 min)"
  TOKEN="$(timeout 240 oc exec -n "${GITLAB_NAMESPACE}" "${TOOLBOX}" -- \
    gitlab-rails runner "
      u = User.find_by_username('root')
      t = u.personal_access_tokens.find_by(name: 'demo-seed') ||
          u.personal_access_tokens.create!(
            name: 'demo-seed',
            scopes: ['api','write_repository'],
            expires_at: 90.days.from_now)
      puts t.token
    " 2>/dev/null | tail -1 | tr -d '\r')" || true

  [[ -n "${TOKEN}" ]] || die "toolbox token mint failed or timed out after 240s.

    Mint one in the UI instead, which is faster and has no moving parts:
      ${BASE}/-/user_settings/personal_access_tokens
      scopes: api, write_repository
    Then: export GITLAB_TOKEN=<token> && ./scripts/seed-gitlab.sh"
fi

API="${BASE}/api/v4"
AUTH=(-H "PRIVATE-TOKEN: ${TOKEN}")

# Fail here, clearly, rather than three steps later on a confusing 404.
"${CURL[@]}" "${AUTH[@]}" "${API}/user" >/dev/null 2>&1 \
  || die "the token was rejected (401).

    It must be a PERSONAL access token (starts glpat-), not a project or group
    token, and it needs the 'api' scope, not just 'read_api'.
    Check it directly:
      curl -sk -H \"PRIVATE-TOKEN: \${GITLAB_TOKEN}\" ${API}/user"

info "AI endpoint: ${AI_BASE_URL:-none}"

# --- group and projects -----------------------------------------------------
info "ensuring group ${GITLAB_GROUP}"
"${CURL[@]}" "${AUTH[@]}" -X POST "${API}/groups" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"${GITLAB_GROUP}\",\"path\":\"${GITLAB_GROUP}\",\"visibility\":\"public\"}" \
  >/dev/null 2>&1 || info "  group exists already"

GROUP_ID="$("${CURL[@]}" "${AUTH[@]}" "${API}/groups/${GITLAB_GROUP}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
  || die "could not resolve group ${GITLAB_GROUP}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

publish() {
  local name="$1"
  local src="${REPO_ROOT}/samples/${name}"
  [[ -d "${src}" ]] || die "sample not found: ${src}"

  info "publishing ${name}"
  "${CURL[@]}" "${AUTH[@]}" -X POST "${API}/projects" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${name}\",\"path\":\"${name}\",\"namespace_id\":${GROUP_ID},\"visibility\":\"public\",\"initialize_with_readme\":false}" \
    >/dev/null 2>&1 || info "  project exists already"

  rm -rf "${WORK:?}/${name}"
  cp -r "${src}" "${WORK}/${name}"
  cd "${WORK}/${name}"

  # Render the AI endpoint at publish time rather than committing it to the
  # source repo: the endpoint is environment state, the samples are the asset.
  # ledger-service has no devfile, on purpose.
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
# The part Gitea could not do. Dev Spaces needs an OAuth application registered
# in GitLab so it can fetch devfiles and act on the developer's behalf.
banner "Registering Dev Spaces as an OAuth application"

CALLBACK="https://devspaces.${CLUSTER_APPS_DOMAIN}/api/oauth/callback"
info "callback: ${CALLBACK}"

OAUTH_JSON="$("${CURL[@]}" "${AUTH[@]}" -X POST "${API}/applications" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"devspaces\",\"redirect_uri\":\"${CALLBACK}\",\"scopes\":\"api write_repository openid\"}" \
  2>/dev/null || true)"

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
  warn "OAuth application registration failed, or one already exists."
  warn "If workspaces cannot resolve devfiles, register it by hand at"
  warn "  ${BASE}/admin/applications"
  warn "with callback ${CALLBACK} and scopes: api, write_repository, openid"
fi

banner "Seeded"
cat <<MSG

    Create workspaces from these URLs. Nothing here touches the internet.

      ${BASE}/${GITLAB_GROUP}/payments-service      acts 2 to 4
      ${BASE}/${GITLAB_GROUP}/ansible-automation    act 6
      ${BASE}/${GITLAB_GROUP}/ledger-service        act 5, no devfile on purpose

    GitLab UI: ${BASE}   (root)
      oc get secret gitlab-gitlab-initial-root-password -n ${GITLAB_NAMESPACE} \\
        -o jsonpath='{.data.password}' | base64 -d

MSG

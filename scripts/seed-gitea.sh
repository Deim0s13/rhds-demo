#!/usr/bin/env bash
# Publish the samples into Gitea as standalone repositories.
#
# Pushes straight from your working tree over the Gitea Route. No GitHub
# round-trip, so the demo has no internet dependency at all, and iterating on a
# devfile is a re-seed rather than a commit-push-wait cycle.
#
# Each sample becomes its own repo with the devfile at the root, which is what a
# real team's repository looks like and what makes "paste the repo URL" work.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require git; require curl; require_login

[[ "${DEPLOY_GITEA}" == "true" ]] || die "DEPLOY_GITEA is false. Nothing to seed."
[[ -n "${GITEA_HOST}" ]] || die "Gitea route not found. Has scripts/up.sh run?"

BASE="https://${GITEA_HOST}"
AUTH="-u ${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}"

banner "Seeding ${BASE}/${GITEA_ORG}"
info "AI endpoint: ${AI_BASE_URL:-none}"

# The Route uses the cluster's default certificate, so curl and git both need
# to skip verification here. In a real environment the corporate CA is in the
# trust store and none of this is necessary.
CURL="curl -sk"

info "waiting for the API"
for _ in $(seq 1 60); do
  ${CURL} "${BASE}/api/healthz" >/dev/null 2>&1 && break
  sleep 5
done

${CURL} ${AUTH} "${BASE}/api/v1/user" >/dev/null 2>&1 \
  || die "cannot authenticate as ${GITEA_ADMIN_USER}.
    Check GITEA_ADMIN_USER / GITEA_ADMIN_PASSWORD in demo.env, and the
    admin-creation hook: oc logs deployment/gitea -n ${DEMO_NAMESPACE}"

info "ensuring organisation ${GITEA_ORG}"
${CURL} ${AUTH} -X POST "${BASE}/api/v1/orgs" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${GITEA_ORG}\",\"visibility\":\"public\"}" >/dev/null || true

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

publish() {
  local name="$1"
  local src="${REPO_ROOT}/samples/${name}"
  [[ -d "${src}" ]] || die "sample not found: ${src}"

  info "publishing ${name}"

  ${CURL} ${AUTH} -X POST "${BASE}/api/v1/orgs/${GITEA_ORG}/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"${name}\",\"private\":false,\"auto_init\":false}" >/dev/null || true

  rm -rf "${WORK}/${name}"
  cp -r "${src}" "${WORK}/${name}"
  cd "${WORK}/${name}"

  # Render the AI endpoint into the devfile. Done here rather than committed to
  # the source repo, because the endpoint is environment state and the samples
  # are the asset. ledger-service has no devfile, on purpose.
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
  git remote add origin \
    "https://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}@${GITEA_HOST}/${GITEA_ORG}/${name}.git"
  git push -q -u origin main --force
  cd "${REPO_ROOT}"
}

publish payments-service
publish ansible-automation
publish ledger-service

banner "Seeded"
cat <<MSG

    Create workspaces from these URLs. Nothing here touches the internet.

      ${BASE}/${GITEA_ORG}/payments-service      acts 2 to 4
      ${BASE}/${GITEA_ORG}/ansible-automation    act 6
      ${BASE}/${GITEA_ORG}/ledger-service        act 5, no devfile on purpose

    Gitea UI: ${BASE}  (${GITEA_ADMIN_USER})

    Re-run this any time you change a sample or the AI endpoint. It is a
    force push, so the repos always match your working tree.

MSG

#!/usr/bin/env bash
# Injects Git credentials into the current user's Dev Spaces namespace.
#
# This is the act 6 security segment. The developer never types a credential.
# Run it once after your workspace namespace exists, which happens the first
# time you start a workspace.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login
assert_provisioned_cluster

[[ "${DEPLOY_GITEA}" == "true" ]] || die "DEPLOY_GITEA is false, nothing to inject"
[[ -n "${GITEA_HOST}" ]] || die "Gitea route not found, has up.sh run?"

USER_NAMESPACE="${1:-$(oc get namespace -l app.kubernetes.io/part-of=che.eclipse.org \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)}"

if [[ -z "${USER_NAMESPACE}" ]]; then
  die "could not find a Dev Spaces user namespace.
    Start a workspace once, then re-run. Or pass it explicitly:
      $0 <username>-devspaces"
fi
export USER_NAMESPACE

banner "Injecting Git credentials into ${USER_NAMESPACE}"
render "${REPO_ROOT}/overlays/gitea/03-git-credentials.yaml" | oc apply -f -

cat <<MSG

    Done. Restart any running workspace to pick this up.

    In the workspace, the developer can now clone and push against
    https://${GITEA_HOST} without ever seeing a credential.

    Demo line: the platform provisioned this, not the developer. Nothing
    lands on an endpoint, and revocation is a secret rotation rather than
    a fleet-wide laptop problem.

MSG

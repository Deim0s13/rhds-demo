#!/usr/bin/env bash
# Return the demo to its start state without rebuilding the cluster.
# Run between back-to-back sessions.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login
assert_provisioned_cluster

banner "Deleting DevWorkspaces"
for ns in $(oc get devworkspace --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
  info "clearing ${ns}"
  oc delete devworkspace --all -n "${ns}" --ignore-not-found
done

banner "Restoring ledger-service to its devfile-free state"
if [[ "${DEPLOY_GITLAB}" == "true" ]]; then
  # Act 5 authors and commits a devfile into ledger-service, so that repository
  # is no longer devfile-free afterwards. seed-gitlab.sh force-pushes it back.
  info "re-seeding from the working tree (force push)"
  bash "${REPO_ROOT}/scripts/seed-gitlab.sh"
else
  warn "DEPLOY_GITLAB is false, nothing to re-seed"
fi

banner "Ready"
info "Cluster is intact. Run smoke.sh again to re-warm before the next session."

#!/usr/bin/env bash
# Return the demo to its start state without rebuilding the cluster.
# Run between back-to-back sessions.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login
assert_provisioned_cluster

banner "Deleting DevWorkspaces for $(oc whoami)"
for ns in $(oc get devworkspace --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
  info "clearing ${ns}"
  oc delete devworkspace --all -n "${ns}" --ignore-not-found
done

banner "Reverting the live-authored devfile"
if [[ -f "${REPO_ROOT}/samples/bare-app/devfile.yaml" ]]; then
  rm -f "${REPO_ROOT}/samples/bare-app/devfile.yaml"
  info "removed samples/bare-app/devfile.yaml"
  warn "if you committed and pushed it during the demo, revert that commit too"
else
  info "bare-app is already clean"
fi

banner "Ready"
info "Cluster is intact. Run smoke.sh again to re-warm before the next session."

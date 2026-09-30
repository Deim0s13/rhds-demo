#!/usr/bin/env bash
# Return the demo to its start state without rebuilding the cluster.
# Run between back-to-back sessions.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login
assert_provisioned_cluster

banner "Deleting DevWorkspaces"
NAMESPACES="$(oc get devworkspace --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)"
for ns in ${NAMESPACES}; do
  info "clearing ${ns}"
  oc delete devworkspace --all -n "${ns}" --ignore-not-found
done

banner "Deleting per-user workspace storage"
# DELETING THE WORKSPACE IS NOT ENOUGH, and this cost an afternoon.
#
# Dev Spaces keeps /projects on a per-user PVC that outlives the workspace. Che
# skips cloning when the project directory is already there, so a workspace
# recreated against an updated repository can come up with the OLD clone: an old
# devfile, and no .vscode/extensions.json if you have just added one. Everything
# looks correct and the change is simply absent.
#
# This discards anything uncommitted inside a workspace. That is the intent of a
# reset, but it is worth knowing before you run it mid-rehearsal.
for ns in ${NAMESPACES}; do
  # The PVC cannot go while a pod still mounts it, and the delete will hang on
  # the finalizer rather than fail. Wait for the workspace pods to actually go.
  info "waiting for pods to terminate in ${ns}"
  local_wait=0
  while [[ -n "$(oc get pods -n "${ns}" -o name 2>/dev/null)" ]]; do
    sleep 3; local_wait=$((local_wait+3))
    if (( local_wait > 120 )); then
      warn "pods still present in ${ns} after 2 minutes, skipping its storage"
      continue 2
    fi
  done
  for pvc in $(oc get pvc -n "${ns}" -o name 2>/dev/null); do
    info "deleting ${pvc} in ${ns}"
    oc delete "${pvc}" -n "${ns}" --ignore-not-found --timeout=60s \
      || warn "could not delete ${pvc}, delete it by hand before rehearsing"
  done
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

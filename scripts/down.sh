#!/usr/bin/env bash
# Tear down everything this repo created. Rarely needed given the cluster is
# disposable, but useful when demoing on a shared or longer-lived cluster.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login

read -r -p "This deletes the CheCluster, the operator and ${DEMO_NAMESPACE}. Type the namespace to confirm: " confirm
[[ "${confirm}" == "${DEMO_NAMESPACE}" ]] || die "aborted"

banner "Removing workspaces"
bash "${REPO_ROOT}/scripts/reset.sh" || true

banner "Removing CheCluster"
oc delete checluster devspaces -n "${DEVSPACES_NAMESPACE}" --ignore-not-found --timeout=300s || true

banner "Removing operator"
oc delete subscription devspaces -n openshift-operators --ignore-not-found
oc get csv -n openshift-operators -o name | grep -i devspaces | xargs -r oc delete -n openshift-operators

banner "Removing demo namespace"
oc delete namespace "${DEMO_NAMESPACE}" --ignore-not-found

info "done"

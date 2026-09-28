#!/usr/bin/env bash
# Tear down everything this repo created.
#
# Rarely needed given the cluster is disposable, but useful for testing a
# from-nothing rebuild without waiting for a new environment.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login

read -r -p "This deletes GitLab, the CheCluster, the operators and ${DEMO_NAMESPACE}. Type the demo namespace to confirm: " confirm
[[ "${confirm}" == "${DEMO_NAMESPACE}" ]] || die "aborted"

banner "Removing workspaces"
for ns in $(oc get devworkspace --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
  oc delete devworkspace --all -n "${ns}" --ignore-not-found || true
done

banner "Removing GitLab"
oc delete gitlab gitlab -n "${GITLAB_NAMESPACE}" --ignore-not-found --timeout=300s || true
oc delete namespace "${GITLAB_NAMESPACE}" --ignore-not-found || true

banner "Removing the model"
oc delete inferenceservice "${AI_SERVICE_NAME}" -n "${DEMO_NAMESPACE}" --ignore-not-found || true
oc delete servingruntime vllm-coder-runtime -n "${DEMO_NAMESPACE}" --ignore-not-found || true

banner "Removing CheCluster and operator"
oc delete checluster devspaces -n "${DEVSPACES_NAMESPACE}" --ignore-not-found --timeout=300s || true
oc delete subscription devspaces -n openshift-operators --ignore-not-found || true
oc get csv -n openshift-operators -o name 2>/dev/null | grep -i devspaces \
  | xargs -r oc delete -n openshift-operators || true

banner "Removing the demo namespace"
oc delete namespace "${DEMO_NAMESPACE}" --ignore-not-found || true

banner "Done"
info "Credentials in ~/.config/rhds-demo/ are left alone. Delete the file for"
info "this cluster if you want a genuinely clean rebuild:"
info "  rm $(state_file | xargs dirname)/secrets-*.env"

#!/usr/bin/env bash
# Bring a fresh, disposable OpenShift cluster to demo-ready state.
# Safe to re-run. Expect 10 to 15 minutes on first run, most of it operator install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"

load_env
require oc
require_login

banner "1/6  Dev Spaces operator"
render "${REPO_ROOT}/bootstrap/01-operator.yaml" | oc apply -f -
wait_for_csv "devspaces" "openshift-operators" 600

banner "2/6  Namespaces"
render "${REPO_ROOT}/bootstrap/03-demo-namespace.yaml" | oc apply -f -
oc get namespace "${DEVSPACES_NAMESPACE}" >/dev/null 2>&1 \
  || oc create namespace "${DEVSPACES_NAMESPACE}"

banner "3/6  CheCluster"
render "${REPO_ROOT}/bootstrap/02-checluster.yaml" | oc apply -f -

banner "4/6  Waiting for Dev Spaces to come up"
wait_for_checluster "${DEVSPACES_NAMESPACE}" 900

banner "4b/6  Internal Git (GitLab: ${DEPLOY_GITLAB})"
if [[ "${DEPLOY_GITLAB}" == "true" ]]; then
  [[ -n "${CLUSTER_APPS_DOMAIN}" ]] || die "could not resolve the cluster apps domain"
  info "GitLab will be at https://${GITLAB_HOST}"

  render "${REPO_ROOT}/overlays/gitlab/01-operator.yaml" | oc apply -f -
  wait_for_csv "gitlab-operator" "${GITLAB_NAMESPACE}" 900

  render "${REPO_ROOT}/overlays/gitlab/02-gitlab.yaml" | oc apply -f -
  wait_for_gitlab "${GITLAB_NAMESPACE}" 2400 \
    || die "GitLab did not come up. Check: oc get pods -n ${GITLAB_NAMESPACE}"

  render "${REPO_ROOT}/overlays/gitlab/03-route.yaml" | oc apply -f -

  # Dev Spaces has to trust the Route's certificate before it can fetch a
  # devfile over it. Doing this after the Route exists but before seeding.
  bash "${REPO_ROOT}/scripts/trust-cluster-ca.sh"
else
  warn "DEPLOY_GITLAB is false. The samples will not be published anywhere,"
  warn "so there will be no repository URLs to create workspaces from."
fi

banner "5/6  In-cluster AI model (backend: ${AI_BACKEND})"
case "${AI_BACKEND}" in
  rhoai)
    free_gpu_if_safe
    check_gpu_capacity || die "GPU check failed, see the warnings above"
    oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1 \
      || die "KServe CRDs not found. Is RHOAI installed and the DataScienceCluster reconciled?"
    render "${REPO_ROOT}/overlays/rhoai/01-inference-service.yaml" | oc apply -f -
    render "${REPO_ROOT}/overlays/rhoai/02-network-policy.yaml" | oc apply -f -
    wait_for_inferenceservice "${AI_SERVICE_NAME}" "${DEMO_NAMESPACE}" 1500 || true
    ;;
  ollama)
    render "${REPO_ROOT}/overlays/ollama/01-ollama.yaml" | oc apply -f -
    render "${REPO_ROOT}/overlays/ollama/02-network-policy.yaml" | oc apply -f -
    oc rollout status "deployment/${AI_SERVICE_NAME}" -n "${DEMO_NAMESPACE}" --timeout=600s
    info "pulling ${OLLAMA_MODEL}"
    oc exec -n "${DEMO_NAMESPACE}" "deployment/${AI_SERVICE_NAME}" -- ollama pull "${OLLAMA_MODEL}"
    ;;
  none)
    info "AI_BACKEND is none, skipping the model entirely"
    ;;
esac

banner "5b/6  Publishing samples to GitLab"
if [[ "${DEPLOY_GITLAB}" == "true" ]]; then
  # Seeded after the model so the devfiles carry an endpoint that exists.
  bash "${REPO_ROOT}/scripts/seed-gitlab.sh"
else
  info "skipped"
fi

banner "6/6  Done"
DASHBOARD="$(oc get checluster devspaces -n "${DEVSPACES_NAMESPACE}" -o jsonpath='{.status.cheURL}' 2>/dev/null || true)"
cat <<EOF

  Dashboard      : ${DASHBOARD:-not ready yet, re-check in a minute}
  Demo namespace : ${DEMO_NAMESPACE}
  AI backend     : ${AI_BACKEND}
  Model          : ${AI_MODEL} (in-cluster only, no egress)
  Endpoint       : ${AI_BASE_URL:-none}

  Samples        : https://${GITLAB_HOST:-n/a}/${GITLAB_GROUP}

  Next: run scripts/smoke.sh at least 30 minutes before you present.
        It warms the image pull, which is the single most common way this
        demo falls over in front of a customer.

EOF

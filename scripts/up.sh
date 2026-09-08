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

banner "4b/6  Internal Git (Gitea: ${DEPLOY_GITEA})"
if [[ "${DEPLOY_GITEA}" == "true" ]]; then
  # Build the OpenShift-compliant image first. The upstream one cannot run
  # under restricted-v2; images/gitea/Containerfile explains why.
  render "${REPO_ROOT}/overlays/gitea/00-build.yaml" | oc apply -f -
  if ! oc get istag gitea-openshift:latest -n "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
    info "building the Gitea image (first run only, ~2 minutes)"
    oc start-build gitea-openshift -n "${DEMO_NAMESPACE}" --follow --wait \
      || die "Gitea image build failed. Logs: oc logs bc/gitea-openshift -n ${DEMO_NAMESPACE}"
  else
    info "Gitea image already built"
  fi

  # Route must exist before we seed, because the workspace URLs are the Route.
  render "${REPO_ROOT}/overlays/gitea/01-gitea.yaml" | oc apply -f -
  oc rollout status deployment/gitea -n "${DEMO_NAMESPACE}" --timeout=600s
  GITEA_HOST="$(gitea_host)"
  [[ -n "${GITEA_HOST}" ]] || die "could not resolve the Gitea route hostname"
  export GITEA_HOST
  info "Gitea route: https://${GITEA_HOST}"

  # Re-apply so ROOT_URL carries the now-known hostname.
  render "${REPO_ROOT}/overlays/gitea/01-gitea.yaml" | oc apply -f -
  oc rollout status deployment/gitea -n "${DEMO_NAMESPACE}" --timeout=600s
else
  warn "DEPLOY_GITEA is false. The samples will not be published anywhere,"
  warn "so there will be no repository URLs to create workspaces from."
fi

info "ensuring the admin user exists"
oc exec -n "${DEMO_NAMESPACE}" deployment/gitea -- \
  gitea admin user create \
    --admin --username "${GITEA_ADMIN_USER}" --password "${GITEA_ADMIN_PASSWORD}" \
    --email admin@example.internal --must-change-password=false 2>/dev/null \
  || info "  already exists"

banner "5/6  In-cluster AI model (backend: ${AI_BACKEND})"
case "${AI_BACKEND}" in
  rhoai)
    free_gpu_if_safe
    check_gpu_capacity || die "GPU check failed, see the warnings above"
    oc get crd inferenceservices.serving.kserve.io >/dev/null 2>&1 \
      || die "KServe CRDs not found. Is RHOAI installed and the DataScienceCluster reconciled?"

    info "checking ModelCar reference"
    oc image info "${AI_MODEL_IMAGE#oci://}" >/dev/null 2>&1 \
      || die "cannot resolve ${AI_MODEL_IMAGE}"

    if [[ -z "${AI_RUNTIME_IMAGE}" ]]; then
      info "discovering vLLM runtime image from the cluster"
      AI_RUNTIME_IMAGE="$(discover_vllm_image)" \
        || die "could not find a vllm-cuda runtime template in ${RHOAI_NAMESPACE}."
    fi
    info "vLLM runtime: ${AI_RUNTIME_IMAGE}"

    render "${REPO_ROOT}/overlays/rhoai/01-inference-service.yaml" | oc apply -f -
    render "${REPO_ROOT}/overlays/rhoai/02-network-policy.yaml" | oc apply -f -
    wait_for_inferenceservice "${AI_SERVICE_NAME}" "${DEMO_NAMESPACE}" 3600 \
      || warn "model is not serving..."
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

banner "5b/6  Publishing samples to Gitea"
if [[ "${DEPLOY_GITEA}" == "true" ]]; then
  # Seeded after the model so the devfiles carry an endpoint that exists.
  bash "${REPO_ROOT}/scripts/seed-gitea.sh"
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

  Samples        : https://${GITEA_HOST:-n/a}/${GITEA_ORG}

  Next: run scripts/smoke.sh at least 30 minutes before you present.
        It warms the image pull, which is the single most common way this
        demo falls over in front of a customer.

EOF

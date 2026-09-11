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

  # Envoy Gateway CRDs FIRST, before the operator Subscription.
  #
  # Chart 10.x renders an EnvoyProxy resource even with global.gatewayApi
  # disabled, so these CRDs must exist or the operator retries forever with
  # "no matches for kind EnvoyProxy". Two hard-won details:
  #
  #   --server-side is required. The EnvoyProxy CRD schema exceeds the 256KB
  #   limit on the last-applied-configuration annotation that client-side
  #   apply writes, and fails with "metadata.annotations: Too long".
  #
  #   Order matters. The operator caches API discovery at startup, so a
  #   controller that starts before these CRDs exist never notices them.
  #   Installing first avoids needing to restart it later.
  #
  # The Gateway API CRD rejections in the output are expected and harmless:
  # OpenShift's Ingress Operator owns those and refuses modification.
  info "installing Envoy Gateway CRDs"
  oc apply --server-side \
    -f https://github.com/envoyproxy/gateway/releases/download/v1.2.1/install.yaml \
    2>/dev/null || true
  oc wait --for condition=established --timeout=180s \
    crd/envoyproxies.gateway.envoyproxy.io \
    || die "EnvoyProxy CRD did not establish. Without it the GitLab operator
    cannot reconcile. Check: oc get crd | grep envoyproxy"

  render "${REPO_ROOT}/overlays/gitlab/01-operator.yaml" | oc apply -f -
  wait_for_csv "gitlab-operator" "${GITLAB_NAMESPACE}" 900

  # Chart 10.x requires external PostgreSQL, Redis and object storage. These
  # are ours to run now, which is closer to how a bank would deploy it anyway.
  info "deploying GitLab dependencies"
  render "${REPO_ROOT}/overlays/gitlab/00-postgres.yaml" | oc apply -f -
  render "${REPO_ROOT}/overlays/gitlab/00-redis.yaml" | oc apply -f -
  render "${REPO_ROOT}/overlays/gitlab/00-minio.yaml" | oc apply -f -

  oc rollout status statefulset/gitlab-postgresql -n "${GITLAB_NAMESPACE}" --timeout=600s
  oc rollout status deployment/gitlab-redis -n "${GITLAB_NAMESPACE}" --timeout=600s
  oc rollout status deployment/gitlab-minio -n "${GITLAB_NAMESPACE}" --timeout=600s

  info "waiting for extensions and buckets"
  oc wait --for=condition=complete job/gitlab-postgresql-extensions \
    -n "${GITLAB_NAMESPACE}" --timeout=300s \
    || { oc logs job/gitlab-postgresql-extensions -n "${GITLAB_NAMESPACE}" --tail=20 || true
         die "PostgreSQL extension setup failed"; }
  oc wait --for=condition=complete job/gitlab-minio-buckets \
    -n "${GITLAB_NAMESPACE}" --timeout=300s \
    || { oc logs job/gitlab-minio-buckets -n "${GITLAB_NAMESPACE}" --tail=20 || true
         die "MinIO bucket creation failed"; }

  render "${REPO_ROOT}/overlays/gitlab/02-gitlab.yaml" | oc apply -f -

  # Belt and braces. The CRDs are installed before the operator above, so its
  # discovery cache should already be warm, but a controller that started at
  # any point before them will loop on "no matches for kind" forever and give
  # no clue why. Ten seconds here is cheaper than an afternoon.
  info "cycling the operator to refresh its API discovery cache"
  oc delete pod -n "${GITLAB_NAMESPACE}" -l control-plane=controller-manager \
    --ignore-not-found >/dev/null 2>&1 || true
  sleep 20

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
    # The runtime image must come from this cluster's own template. RHOAI
    # ships images matched to its version; a pinned guess fails deep inside
    # vLLM startup after an 18GB pull.
    if [[ -z "${AI_RUNTIME_IMAGE}" ]]; then
      info "discovering vLLM runtime image from the cluster"
      AI_RUNTIME_IMAGE="$(discover_vllm_image)" \
        || die "could not find a vllm-cuda runtime template in ${RHOAI_NAMESPACE}.
    Set AI_RUNTIME_IMAGE in demo.env explicitly, or check RHOAI is installed."
    fi
    info "vLLM runtime: ${AI_RUNTIME_IMAGE}"

    render "${REPO_ROOT}/overlays/rhoai/01-inference-service.yaml" | oc apply -f -
    render "${REPO_ROOT}/overlays/rhoai/02-network-policy.yaml" | oc apply -f -
    wait_for_inferenceservice "${AI_SERVICE_NAME}" "${DEMO_NAMESPACE}" 3600 || true
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

#!/usr/bin/env bash
# Bring a fresh, disposable OpenShift cluster to demo-ready state.
#
# Safe to re-run. On a first run expect 45 to 90 minutes, almost all of it image
# pulls: the vLLM runtime is around 18GB, the ModelCar 6.4GB, and GitLab has a
# dozen images of its own plus roughly 12 minutes of database migrations.
#
# RUN PREFLIGHT FIRST. It checks in 30 seconds most of what would otherwise fail
# 40 minutes in:
#   ./scripts/preflight.sh && ./scripts/up.sh 2>&1 | tee up-$(date +%H%M).log
#
# Always pipe through tee. A wait this long outlives a terminal restart, and
# losing the output means losing the diagnosis.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"

load_env
require oc
require_login

# Recorded up front, not at the end. The sub-scripts up.sh calls (seed-gitlab.sh)
# check this to catch a stray kube context switch, and they run before stage 6.
# The point is which cluster we pointed at, not whether the run succeeded.
record_cluster

banner "1/6  Dev Spaces operator"
render "${REPO_ROOT}/bootstrap/01-operator.yaml" | oc apply -f -
wait_for_csv "devspaces" "openshift-operators" 900

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
  # Chart 10.x renders Gateway API resources including an EnvoyProxy even with
  # global.gatewayApi disabled, so these CRDs must exist or the operator retries
  # forever with "no matches for kind EnvoyProxy". Two hard-won details:
  #
  #   --server-side is required. The EnvoyProxy CRD schema exceeds the 256KB
  #   limit on the last-applied-configuration annotation that client-side apply
  #   writes, and fails with "metadata.annotations: Too long".
  #
  #   Order matters. The operator caches API discovery at startup, so a
  #   controller that starts before these CRDs exist never notices them.
  #   Installing first avoids needing to restart it later. That cost a day.
  #
  # The Gateway API CRD rejections in the output are expected and harmless:
  # OpenShift's Ingress Operator owns those and refuses modification.
  info "installing Envoy Gateway CRDs (${ENVOY_GATEWAY_VERSION})"
  oc apply --server-side \
    -f "https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml" \
    2>/dev/null || true
  oc wait --for condition=established --timeout=180s \
    crd/envoyproxies.gateway.envoyproxy.io \
    || die "EnvoyProxy CRD did not establish. Without it the GitLab operator
    cannot reconcile. Check: oc get crd | grep envoyproxy"

  render "${REPO_ROOT}/overlays/gitlab/01-operator.yaml" | oc apply -f -
  wait_for_csv "gitlab-operator" "${GITLAB_NAMESPACE}" 900

  # The operator accepts only the chart versions it ships, and the list moves
  # with each release. Discovered rather than pinned, because a pinned version
  # goes stale and fails at admission on a future environment.
  if [[ -z "${GITLAB_CHART_VERSION}" ]]; then
    info "discovering supported chart version"
    GITLAB_CHART_VERSION="$(discover_gitlab_chart_version)" \
      || die "could not determine a supported chart version.
    Set GITLAB_CHART_VERSION in demo.env explicitly. To see the list, apply a
    GitLab CR with a bogus version and read the rejection."
  fi
  info "chart version: ${GITLAB_CHART_VERSION}"

  # Chart 10.x removed the bundled PostgreSQL, Redis and object storage, so
  # those are ours to run now. Closer to how a bank would deploy it anyway.
  info "deploying GitLab dependencies"

  # Jobs are immutable. oc apply silently keeps the old spec, so a fixed Job
  # appears not to have changed. Delete BEFORE applying, not after.
  oc delete job gitlab-postgresql-extensions -n "${GITLAB_NAMESPACE}" \
    --ignore-not-found --wait=true

  render "${REPO_ROOT}/overlays/gitlab/00-postgres.yaml"  | oc apply -f -
  render "${REPO_ROOT}/overlays/gitlab/00-redis.yaml"     | oc apply -f -
  render "${REPO_ROOT}/overlays/gitlab/00-seaweedfs.yaml" | oc apply -f -

  oc rollout status statefulset/gitlab-postgresql -n "${GITLAB_NAMESPACE}" --timeout=600s
  oc rollout status deployment/gitlab-redis       -n "${GITLAB_NAMESPACE}" --timeout=600s
  oc rollout status deployment/gitlab-seaweedfs   -n "${GITLAB_NAMESPACE}" --timeout=600s

  info "waiting for PostgreSQL extensions"
  oc wait --for=condition=complete job/gitlab-postgresql-extensions \
    -n "${GITLAB_NAMESPACE}" --timeout=300s \
    || { oc logs job/gitlab-postgresql-extensions -n "${GITLAB_NAMESPACE}" --tail=20 || true
         die "PostgreSQL extension setup failed"; }

  # Buckets created by exec into the running pod rather than a separate Job.
  # weed shell is an interactive tool. Piping a command to it works from inside
  # the SeaweedFS pod, but from another pod it hung indefinitely on the master
  # address, and a Job without activeDeadlineSeconds hangs up.sh with it.
  info "creating object storage buckets"
  for b in gitlab-artifacts gitlab-lfs gitlab-uploads gitlab-packages \
           gitlab-mr-diffs gitlab-terraform-state gitlab-ci-secure-files \
           gitlab-dependency-proxy gitlab-pages gitlab-backups gitlab-tmp; do
    oc exec -n "${GITLAB_NAMESPACE}" deployment/gitlab-seaweedfs -- sh -c \
      "echo 's3.bucket.create -name ${b}' | timeout 20 weed shell -master=localhost:9333" \
      >/dev/null 2>&1 || warn "  could not create bucket ${b}"
  done
  # Print what actually exists. A silent failure then shows on screen rather
  # than being assumed from an exit code.
  info "buckets present:"
  oc exec -n "${GITLAB_NAMESPACE}" deployment/gitlab-seaweedfs -- sh -c \
    "echo 's3.bucket.list' | timeout 20 weed shell -master=localhost:9333" \
    2>/dev/null | sed 's/^/      /' || warn "  could not list buckets"

  render "${REPO_ROOT}/overlays/gitlab/02-gitlab.yaml" | oc apply -f -

  # Belt and braces. The CRDs are installed before the operator above, so its
  # discovery cache should already be warm, but a controller that started at any
  # point before them loops on "no matches for kind" forever and gives no clue
  # why. Ten seconds here is cheaper than an afternoon.
  info "cycling the operator to refresh its API discovery cache"
  oc delete pod -n "${GITLAB_NAMESPACE}" -l control-plane=controller-manager \
    --ignore-not-found >/dev/null 2>&1 || true
  sleep 20

  wait_for_gitlab "${GITLAB_NAMESPACE}" 3600 \
    || die "GitLab did not come up. Check: oc get pods -n ${GITLAB_NAMESPACE}"

  render "${REPO_ROOT}/overlays/gitlab/03-route.yaml" | oc apply -f -

  # Dev Spaces must trust the Route's certificate before it can fetch a devfile
  # over it. After the Route exists, before seeding.
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

    # Check the ModelCar reference resolves before waiting 25 minutes to find
    # out it does not. Catalogue tags move, and a bad reference fails silently
    # in an init container rather than at apply time.
    info "checking ModelCar reference"
    oc image info "${AI_MODEL_IMAGE#oci://}" >/dev/null 2>&1 \
      || die "cannot resolve ${AI_MODEL_IMAGE}
    The tag does not exist, or the registry is unreachable. List what is there:
      skopeo list-tags docker://quay.io/redhat-ai-services/modelcar-catalog | head -40"

    # The runtime image must come from this cluster's own template.
    if [[ -z "${AI_RUNTIME_IMAGE}" ]]; then
      info "discovering vLLM runtime image from the cluster"
      AI_RUNTIME_IMAGE="$(discover_vllm_image)" \
        || die "could not find a vllm-cuda runtime template in ${RHOAI_NAMESPACE}.
    Set AI_RUNTIME_IMAGE in demo.env explicitly, or check RHOAI is installed."
    fi
    info "vLLM runtime: ${AI_RUNTIME_IMAGE}"

    render "${REPO_ROOT}/overlays/rhoai/01-inference-service.yaml" | oc apply -f -
    render "${REPO_ROOT}/overlays/rhoai/02-network-policy.yaml"    | oc apply -f -
    wait_for_inferenceservice "${AI_SERVICE_NAME}" "${DEMO_NAMESPACE}" 3600 \
      || warn "model is not serving yet. Dev Spaces itself is fine, so acts 1 to 5
    will run normally, and KServe may still bring it up on its own. Check with
    oc get inferenceservice -n ${DEMO_NAMESPACE}, or set AI_BACKEND=ollama."
    ;;
  ollama)
    render "${REPO_ROOT}/overlays/ollama/01-ollama.yaml"         | oc apply -f -
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
  GitLab         : https://${GITLAB_HOST:-n/a}
  Samples        : https://${GITLAB_HOST:-n/a}/${GITLAB_GROUP}
  Demo namespace : ${DEMO_NAMESPACE}
  AI backend     : ${AI_BACKEND}
  Model          : ${AI_MODEL} (in-cluster only, no egress)
  Endpoint       : ${AI_BASE_URL:-none}
  Chart version  : ${GITLAB_CHART_VERSION:-n/a}

  GitLab root password:
    oc get secret gitlab-gitlab-initial-root-password -n ${GITLAB_NAMESPACE} \\
      -o jsonpath='{.data.password}' | base64 -d

  Next:
    1. ./scripts/smoke.sh
    2. Create a workspace from the payments-service URL once and complete the
       GitLab OAuth handshake. It only happens on first use, and you do not
       want to be typing a root password on stage.

EOF

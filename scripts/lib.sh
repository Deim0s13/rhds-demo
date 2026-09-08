#!/usr/bin/env bash
# Shared helpers. Sourced, not executed.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

banner() { printf '\n\033[1;31m==> %s\033[0m\n' "$*"; }
info()   { printf '    %s\n' "$*"; }
warn()   { printf '\033[1;33m    warning: %s\033[0m\n' "$*" >&2; }
die()    { printf '\033[1;31m    error: %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH"
}

require_login() {
  oc whoami >/dev/null 2>&1 || die "not logged in. Run: oc login --token=... --server=..."
  info "logged in as $(oc whoami) on $(oc whoami --show-server)"
}

load_env() {
  if [[ -f "${REPO_ROOT}/demo.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${REPO_ROOT}/demo.env"; set +a
  else
    die "demo.env not found. Copy demo.env.example to demo.env and edit it."
  fi
  : "${DEMO_NAMESPACE:?}" "${DEVSPACES_NAMESPACE:?}" "${DEVSPACES_CHANNEL:?}"
  : "${GIT_ORG:?}" "${GIT_REPO:?}" "${GIT_BRANCH:?}"
  AI_BACKEND="${AI_BACKEND:-none}"
  AI_MODEL="${AI_MODEL:-qwen2.5-coder-7b-instruct}"
  AI_SERVICE_NAME="${AI_SERVICE_NAME:-coder-model}"
  RHOAI_NAMESPACE="${RHOAI_NAMESPACE:-redhat-ods-applications}"
  OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:1.5b}"
  case "${AI_BACKEND}" in
    rhoai|ollama|none) ;;
    *) die "AI_BACKEND must be one of: rhoai, ollama, none (got '${AI_BACKEND}')" ;;
  esac
  [[ "${AI_BACKEND}" == "rhoai" ]] && : "${AI_MODEL_IMAGE:?AI_MODEL_IMAGE is required when AI_BACKEND=rhoai}"
  AI_BASE_URL="$(ai_base_url)"
  FREE_GPU="${FREE_GPU:-true}"
  RHDP_SAMPLE_NAMESPACES="${RHDP_SAMPLE_NAMESPACES:-my-first-model}"
  DEPLOY_GITEA="${DEPLOY_GITEA:-true}"
  GITEA_ORG="${GITEA_ORG:-platform-engineering}"
  GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-platform-admin}"
  GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-ChangeMe-PerEnvironment}"
  GITEA_HOST="${GITEA_HOST:-$(gitea_host)}"
}

# Route hostname, resolved from the cluster. The Route, not the Service DNS:
# the browser has to resolve it when creating a workspace, and the workspace
# pod has to resolve it when cloning. Only the Route satisfies both.
gitea_host() {
  oc get route gitea -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

# The single point of truth for what the workspace talks to. Both backends
# expose an OpenAI-compatible API, which is why swapping them is a variable
# change rather than a fork of the demo.
ai_base_url() {
  case "${AI_BACKEND}" in
    rhoai)
      echo "http://${AI_SERVICE_NAME}-predictor.${DEMO_NAMESPACE}.svc.cluster.local:8080/v1"
      ;;
    ollama)
      echo "http://${AI_SERVICE_NAME}.${DEMO_NAMESPACE}.svc.cluster.local:11434/v1"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Substitute placeholders in a manifest or devfile. Keeps every cluster-specific
# value in demo.env and nothing in the committed YAML.
render() {
  local out
  out="$(sed \
    -e "s|DEMO_NAMESPACE_PLACEHOLDER|${DEMO_NAMESPACE}|g" \
    -e "s|DEVSPACES_NAMESPACE_PLACEHOLDER|${DEVSPACES_NAMESPACE}|g" \
    -e "s|CHANNEL_PLACEHOLDER|${DEVSPACES_CHANNEL}|g" \
    -e "s|GIT_ORG_PLACEHOLDER|${GIT_ORG}|g" \
    -e "s|GIT_REPO_PLACEHOLDER|${GIT_REPO}|g" \
    -e "s|GIT_BRANCH_PLACEHOLDER|${GIT_BRANCH}|g" \
    -e "s|AI_MODEL_IMAGE_PLACEHOLDER|${AI_MODEL_IMAGE:-}|g" \
    -e "s|AI_MODEL_PLACEHOLDER|${AI_MODEL:-}|g" \
    -e "s|AI_SERVICE_NAME_PLACEHOLDER|${AI_SERVICE_NAME:-}|g" \
    -e "s|AI_BASE_URL_PLACEHOLDER|${AI_BASE_URL:-}|g" \
    -e "s|VLLM_IMAGE_PLACEHOLDER|${AI_RUNTIME_IMAGE:-}|g" \
    -e "s|GITEA_HOST_PLACEHOLDER|${GITEA_HOST:-}|g" \
    -e "s|GITEA_ORG_PLACEHOLDER|${GITEA_ORG:-}|g" \
    -e "s|GITEA_ADMIN_USER_PLACEHOLDER|${GITEA_ADMIN_USER:-}|g" \
    -e "s|GITEA_ADMIN_PASSWORD_PLACEHOLDER|${GITEA_ADMIN_PASSWORD:-}|g" \
    -e "s|USER_NAMESPACE_PLACEHOLDER|${USER_NAMESPACE:-}|g" \
    "$1")"

  # Nothing should reach the cluster with a placeholder still in it. An
  # unsubstituted image name fails an hour later as InvalidImageName, which
  # reads like a registry problem rather than a scripting one.
  if grep -q 'PLACEHOLDER' <<< "${out}"; then
    warn "unsubstituted placeholders in $1:"
    grep -o '[A-Z_]*PLACEHOLDER' <<< "${out}" | sort -u | sed 's/^/      /' >&2
    die "refusing to apply. A variable is empty or a render rule is missing."
  fi
  echo "${out}"
}

wait_for_csv() {
  local name="$1" ns="$2" timeout="${3:-600}" elapsed=0
  info "waiting for ${name} CSV in ${ns}"
  while (( elapsed < timeout )); do
    local phase
    phase="$(oc get csv -n "${ns}" -o jsonpath="{.items[?(@.spec.displayName!='')].status.phase}" 2>/dev/null | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    if oc get csv -n "${ns}" 2>/dev/null | grep -qi "^${name}.*Succeeded"; then
      info "operator ready"; return 0
    fi
    sleep 10; elapsed=$((elapsed+10))
    (( elapsed % 60 == 0 )) && info "  still waiting (${elapsed}s, phases: ${phase:-none})"
  done
  die "timed out waiting for the ${name} operator"
}

wait_for_checluster() {
  local ns="$1" timeout="${2:-900}" elapsed=0
  while (( elapsed < timeout )); do
    local phase
    phase="$(oc get checluster devspaces -n "${ns}" -o jsonpath='{.status.chePhase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Active" ]]; then
      info "Dev Spaces is Active"; return 0
    fi
    sleep 15; elapsed=$((elapsed+15))
    (( elapsed % 60 == 0 )) && info "  still waiting (${elapsed}s, phase: ${phase:-pending})"
  done
  die "timed out waiting for the CheCluster to become Active"
}

wait_for_inferenceservice() {
  local name="$1" ns="$2" timeout="${3:-1200}" elapsed=0
  info "waiting for InferenceService ${name} (first model pull is the slow part)"
  while (( elapsed < timeout )); do
    local ready
    ready="$(oc get inferenceservice "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${ready}" == "True" ]]; then
      info "model is serving"; return 0
    fi
    # A Pending pod alongside a Running one is a stuck rolling update on a
    # single-GPU cluster, not a failure to start. Say so rather than waiting.
    if [[ -n "$(oc get pods -n "${ns}" -l component=predictor \
         --field-selector status.phase=Running -o name 2>/dev/null)" ]] && \
       [[ -n "$(oc get pods -n "${ns}" -l component=predictor \
         --field-selector status.phase=Pending -o name 2>/dev/null)" ]]; then
      warn "an older predictor is serving while a new one waits for the GPU."
      warn "the model works; the rolling update cannot complete on one GPU."
      warn "clear the stale ReplicaSet, or set deploymentStrategy Recreate."
      return 1
    fi
    sleep 20; elapsed=$((elapsed+20))
    (( elapsed % 60 == 0 )) && info "  still waiting (${elapsed}s)"
  done
  warn "an older predictor is serving while a new one waits for the GPU."
  warn "the model works, but the rolling update cannot complete on one GPU."
  warn "clear the stale ReplicaSet, or set deploymentStrategy Recreate."
  return 0
}

# Read the vLLM runtime image from the cluster's own template. RHOAI ships
# runtime images matched to its version, so discovering beats pinning: a
# mismatched runtime fails deep in vLLM startup after an 18GB pull.
discover_vllm_image() {
  local tmpl img
  tmpl="$(oc get templates -n "${RHOAI_NAMESPACE}" -o name 2>/dev/null \
    | grep -i 'vllm-cuda' | head -1)"
  [[ -n "${tmpl}" ]] || return 1
  img="$(oc get "${tmpl}" -n "${RHOAI_NAMESPACE}" \
    -o jsonpath='{.objects[0].spec.containers[0].image}' 2>/dev/null)"
  [[ -n "${img}" ]] || return 1
  echo "${img}"
}

# Free the GPU held by known, disposable RHDP sample workloads.
#
# We act ONLY on namespaces in an explicit allow-list, and only when they are
# actually holding a GPU. Deleting arbitrary namespaces we do not own is not
# this script's job: it has to stay safe to run anywhere, including on a shared
# or customer cluster. Anything not on the list produces a warning and nothing
# else. Set FREE_GPU=false to disable and warn only.
free_gpu_if_safe() {
  local holders holder
  holders="$(oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' -v ns="${DEMO_NAMESPACE}" '$3 != "" && $1 != ns {print $1}' | sort -u)"

  if [[ -z "${holders}" ]]; then
    info "no competing GPU workloads"
    return 0
  fi

  for holder in ${holders}; do
    if [[ "${FREE_GPU}" == "true" ]] && grep -qw -- "${holder}" <<< "${RHDP_SAMPLE_NAMESPACES}"; then
      info "known RHDP sample namespace '${holder}' is holding a GPU, deleting"
      oc delete namespace "${holder}" --wait=true
    else
      warn "namespace '${holder}' is holding a GPU and is not a known RHDP sample."
      warn "  On a single-GPU cluster the predictor will sit Pending."
      warn "  Inspect it with: ./scripts/gpu-claims.sh"
      warn "  Free it and re-run, or set AI_BACKEND=ollama in demo.env."
    fi
  done
}

check_gpu_capacity() {
  local total used free
  total="$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' | paste -sd+ - | bc 2>/dev/null || echo 0)"
  total="${total:-0}"

  if (( total < 1 )); then
    warn "no allocatable nvidia.com/gpu on any node"
    warn "either the GPU operator has not finished reconciling, or this is not"
    warn "the RHOAI environment you think it is"
    warn "fallback: set AI_BACKEND=ollama in demo.env and re-run up.sh"
    return 1
  fi

  # Capacity is not availability. RHOAI demo environments frequently arrive with
  # a sample workload already holding the GPU, which lets a naive capacity check
  # pass and then leaves the InferenceService Pending with no obvious cause.
  # Count only GPUs held OUTSIDE the demo namespace. Our own predictor
  # legitimately holds one once the model is serving, and counting it would
  # make the check fail precisely when everything is working.
  used="$(oc get pods --all-namespaces \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{"\t"}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' -v ns="${DEMO_NAMESPACE}" '$2 != "" && $1 != ns {print $2}' \
    | paste -sd+ - | bc 2>/dev/null || echo 0)"
  used="${used:-0}"
  free=$(( total - used ))

  info "GPU: ${total} allocatable, ${used} held outside ${DEMO_NAMESPACE}, ${free} available to us"

  if (( free < 1 )); then
    warn ""
    warn "Every GPU is already claimed. This is normal on a freshly provisioned"
    warn "RHOAI environment: they often ship with a sample model already served."
    warn "Nothing here will schedule until you free one."
    warn ""
    warn "See what is holding them:"
    warn "  ./scripts/gpu-claims.sh"
    warn ""
    warn "Then either scale down or delete the pre-existing workload, or set"
    warn "AI_BACKEND=ollama in demo.env if you would rather not touch it."
    return 1
  fi
}

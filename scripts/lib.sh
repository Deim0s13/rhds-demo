#!/usr/bin/env bash
# Shared helpers. Sourced, not executed.
#
# EVERYTHING BELOW MUST LIVE INSIDE A FUNCTION. A bare statement here runs on
# every source and broke every script in the repo once already, with an unbound
# variable error that looked like a cluster problem.

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
  CURRENT_SERVER="$(oc whoami --show-server)"
  info "logged in as $(oc whoami) on ${CURRENT_SERVER}"
}

# --- configuration ----------------------------------------------------------

load_env() {
  if [[ -f "${REPO_ROOT}/demo.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${REPO_ROOT}/demo.env"; set +a
  else
    die "demo.env not found. Copy demo.env.example to demo.env and edit it."
  fi

  : "${DEMO_NAMESPACE:?}" "${DEVSPACES_NAMESPACE:?}" "${DEVSPACES_CHANNEL:?}"
  : "${GIT_ORG:?}" "${GIT_REPO:?}" "${GIT_BRANCH:?}"

  # --- AI backend ---
  AI_BACKEND="${AI_BACKEND:-none}"
  AI_MODEL="${AI_MODEL:-llama-3.2-3b-instruct}"
  AI_SERVICE_NAME="${AI_SERVICE_NAME:-coder-model}"
  RHOAI_NAMESPACE="${RHOAI_NAMESPACE:-redhat-ods-applications}"
  OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:1.5b}"
  # Empty means discover from the cluster's own vllm-cuda-runtime-template.
  AI_RUNTIME_IMAGE="${AI_RUNTIME_IMAGE:-}"

  case "${AI_BACKEND}" in
    rhoai|ollama|none) ;;
    *) die "AI_BACKEND must be one of: rhoai, ollama, none (got '${AI_BACKEND}')" ;;
  esac
  [[ "${AI_BACKEND}" == "rhoai" ]] \
    && : "${AI_MODEL_IMAGE:?AI_MODEL_IMAGE is required when AI_BACKEND=rhoai}"
  AI_BASE_URL="$(ai_base_url)"

  # --- GPU handling ---
  FREE_GPU="${FREE_GPU:-true}"
  RHDP_SAMPLE_NAMESPACES="${RHDP_SAMPLE_NAMESPACES:-my-first-model}"

  # --- internal Git ---
  DEPLOY_GITLAB="${DEPLOY_GITLAB:-true}"
  GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab-system}"
  GITLAB_GROUP="${GITLAB_GROUP:-platform-engineering}"
  CLUSTER_APPS_DOMAIN="${CLUSTER_APPS_DOMAIN:-$(cluster_apps_domain)}"
  GITLAB_HOST="${GITLAB_HOST:-gitlab.${CLUSTER_APPS_DOMAIN}}"
  # Empty means discover from the operator's admission webhook. The accepted
  # list moves with each operator release, so pinning goes stale.
  GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-}"
  ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.2.1}"

  load_or_generate_secrets
}

# The cluster's wildcard apps domain. Everything routable hangs off this and it
# changes with every environment, so it is discovered rather than configured.
cluster_apps_domain() {
  oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.status.domain}' 2>/dev/null || true
}

gitlab_host() {
  oc get route gitlab -n "${GITLAB_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

# Both AI backends expose an OpenAI-compatible API, which is why swapping them
# is a variable change rather than a fork of the demo.
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

# --- credentials ------------------------------------------------------------

# Dependency credentials for PostgreSQL, Redis and object storage.
#
# These live OUTSIDE the repository, under ~/.config/rhds-demo/. They were
# previously written to .demo-secrets in the working tree and were committed and
# published twice, because a gitignore entry is a control you have to remember
# rather than one that holds by construction. Nothing sensitive should exist
# inside the repo for git to pick up in the first place.
#
# Keyed by cluster, so rotating environments do not collide and an old cluster's
# credentials are never silently reused against a new database.
#
# CHANGING THIS PATH IS ITSELF A ROTATION. A new path means new values, and
# PostgreSQL and object storage only accept new credentials on an EMPTY volume.
load_or_generate_secrets() {
  local dir="${XDG_CONFIG_HOME:-${HOME}/.config}/rhds-demo"
  local key f
  key="$(oc whoami --show-server 2>/dev/null | sed -e 's|https://||' -e 's|[:/].*$||' || true)"
  key="${key:-default}"
  f="${dir}/secrets-${key}.env"

  # Hard stop if the old in-repo file is still present. Ignoring it silently is
  # how the leak recurred: the file gets regenerated, then committed.
  local legacy="${REPO_ROOT}/.demo-secrets"
  if [[ -f "${legacy}" ]]; then
    warn "found .demo-secrets in the working tree."
    warn "credentials no longer live in the repo. Delete it:"
    warn "  rm ${legacy}"
    die "refusing to run while a credentials file sits inside the repository."
  fi

  mkdir -p "${dir}"
  chmod 700 "${dir}"

  if [[ -f "${f}" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${f}"; set +a
    info "using cached credentials for ${key}"
  else
    umask 077
    cat > "${f}" <<EOS
# Generated by scripts/lib.sh for ${key}. Outside the repository, by design.
#
# Delete to rotate, but PostgreSQL and object storage only accept new
# credentials on an EMPTY volume, so their PVCs must go too, and Redis needs a
# pod restart. Half-rotating leaves authentication failures that look like
# configuration errors. See docs/RUNBOOK.md.
DB_PASSWORD="$(openssl rand -hex 16)"
DB_ADMIN_PASSWORD="$(openssl rand -hex 16)"
REDIS_PASSWORD="$(openssl rand -hex 16)"
S3_ACCESS_KEY="$(openssl rand -hex 8)"
S3_SECRET_KEY="$(openssl rand -hex 24)"
EOS
    # shellcheck disable=SC1090
    set -a; source "${f}"; set +a
    info "generated credentials for ${key} in ${f}"
  fi

  # MINIO_* are historical names from before the switch to SeaweedFS. Aliased so
  # a credentials file generated earlier still matches what a running database
  # was initialised with.
  S3_ACCESS_KEY="${S3_ACCESS_KEY:-${MINIO_ACCESS_KEY:-}}"
  S3_SECRET_KEY="${S3_SECRET_KEY:-${MINIO_SECRET_KEY:-}}"
}

# --- cluster state ----------------------------------------------------------

# up.sh records which cluster it provisioned so the other scripts can notice a
# stray kube context switch. Without this, every check fails against a cluster
# that was never set up and the output reads like a broken demo rather than a
# wrong kubeconfig. Kept outside the repo alongside the credentials.
state_file() {
  echo "${XDG_CONFIG_HOME:-${HOME}/.config}/rhds-demo/state.env"
}

record_cluster() {
  local f; f="$(state_file)"
  mkdir -p "$(dirname "${f}")"
  cat > "${f}" <<EOS
PROVISIONED_SERVER="${CURRENT_SERVER}"
PROVISIONED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PROVISIONED_BACKEND="${AI_BACKEND}"
EOS
}

assert_provisioned_cluster() {
  local f; f="$(state_file)"
  if [[ ! -f "${f}" ]]; then
    warn "no record of a provisioned cluster. If this is a fresh environment, run scripts/up.sh first."
    return 0
  fi
  # shellcheck disable=SC1090
  source "${f}"

  if [[ "${CURRENT_SERVER}" != "${PROVISIONED_SERVER}" ]]; then
    die "wrong cluster.
    provisioned : ${PROVISIONED_SERVER}
    current     : ${CURRENT_SERVER}
    Your kube context has moved since up.sh ran. Log back into the demo
    cluster, or run up.sh here if this is a new environment."
  fi

  # These environments expire after about five days. Better to know now than on
  # the morning of a session.
  local started now age
  started="$(date -u -d "${PROVISIONED_AT}" +%s 2>/dev/null \
    || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "${PROVISIONED_AT}" +%s 2>/dev/null || echo 0)"
  now="$(date -u +%s)"
  if [[ "${started}" != "0" ]]; then
    age=$(( (now - started) / 86400 ))
    if (( age >= 4 )); then
      warn "this environment was provisioned ${age} days ago and they typically last 5."
      warn "request a new one before your next session."
    fi
  fi
}

# --- rendering --------------------------------------------------------------

# Substitute placeholders in a manifest. Every cluster-specific value comes from
# demo.env, from the credentials file, or is discovered at runtime. Nothing
# environment-specific belongs in committed YAML.
#
# Refuses to emit anything with an unresolved placeholder, in EITHER of the two
# ways that can happen:
#
#   1. No substitution rule exists for it. Easy to spot.
#   2. A rule exists but the variable is empty, so it substitutes nothing.
#      This is the dangerous one: the manifest applies cleanly and then fails
#      much later as InvalidImageName or similar, which reads like a registry
#      problem rather than a scripting one. It cost most of a day once.
render() {
  local file="$1"
  local -a pairs=(
    DEMO_NAMESPACE_PLACEHOLDER        "${DEMO_NAMESPACE:-}"
    DEVSPACES_NAMESPACE_PLACEHOLDER   "${DEVSPACES_NAMESPACE:-}"
    CHANNEL_PLACEHOLDER               "${DEVSPACES_CHANNEL:-}"
    GIT_ORG_PLACEHOLDER               "${GIT_ORG:-}"
    GIT_REPO_PLACEHOLDER              "${GIT_REPO:-}"
    GIT_BRANCH_PLACEHOLDER            "${GIT_BRANCH:-}"
    AI_MODEL_IMAGE_PLACEHOLDER        "${AI_MODEL_IMAGE:-}"
    AI_MODEL_PLACEHOLDER              "${AI_MODEL:-}"
    AI_SERVICE_NAME_PLACEHOLDER       "${AI_SERVICE_NAME:-}"
    AI_BASE_URL_PLACEHOLDER           "${AI_BASE_URL:-}"
    VLLM_IMAGE_PLACEHOLDER            "${AI_RUNTIME_IMAGE:-}"
    GITLAB_HOST_PLACEHOLDER           "${GITLAB_HOST:-}"
    GITLAB_NAMESPACE_PLACEHOLDER      "${GITLAB_NAMESPACE:-}"
    GITLAB_GROUP_PLACEHOLDER          "${GITLAB_GROUP:-}"
    CLUSTER_APPS_DOMAIN_PLACEHOLDER   "${CLUSTER_APPS_DOMAIN:-}"
    GITLAB_CHART_VERSION_PLACEHOLDER  "${GITLAB_CHART_VERSION:-}"
    DB_PASSWORD_PLACEHOLDER           "${DB_PASSWORD:-}"
    DB_ADMIN_PASSWORD_PLACEHOLDER     "${DB_ADMIN_PASSWORD:-}"
    REDIS_PASSWORD_PLACEHOLDER        "${REDIS_PASSWORD:-}"
    S3_ACCESS_KEY_PLACEHOLDER         "${S3_ACCESS_KEY:-}"
    S3_SECRET_KEY_PLACEHOLDER         "${S3_SECRET_KEY:-}"
    USER_NAMESPACE_PLACEHOLDER        "${USER_NAMESPACE:-}"
  )

  local i name val empty=""
  local -a sedargs=()
  for (( i = 0; i < ${#pairs[@]}; i += 2 )); do
    name="${pairs[i]}"
    val="${pairs[i+1]}"
    if [[ -z "${val}" ]] && grep -q "${name}" "${file}"; then
      empty="${empty}      ${name}"$'\n'
    fi
    sedargs+=( -e "s|${name}|${val}|g" )
  done

  if [[ -n "${empty}" ]]; then
    warn "these placeholders appear in ${file} but their value is empty:"
    printf '%s' "${empty}" >&2
    die "refusing to apply. Substituting an empty value produces a manifest that
    applies cleanly and then fails later in a way that looks like an
    infrastructure problem. Check demo.env and the discovery steps in up.sh."
  fi

  local out
  out="$(sed "${sedargs[@]}" "${file}")"

  if grep -q 'PLACEHOLDER' <<< "${out}"; then
    warn "no substitution rule for these placeholders in ${file}:"
    grep -o '[A-Z_]*PLACEHOLDER' <<< "${out}" | sort -u | sed 's/^/      /' >&2
    die "refusing to apply. Add a rule to render() in scripts/lib.sh."
  fi
  echo "${out}"
}

# --- waits ------------------------------------------------------------------

wait_for_csv() {
  local name="$1" ns="$2" timeout="${3:-900}" elapsed=0
  info "waiting for ${name} CSV in ${ns}"
  while (( elapsed < timeout )); do
    if oc get csv -n "${ns}" \
         -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
         | grep -qi "${name}.*Succeeded"; then
      info "operator ready"; return 0
    fi
    sleep 10; elapsed=$((elapsed+10))
    (( elapsed % 60 == 0 )) && info "  still waiting (${elapsed}s)"
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
  local name="$1" ns="$2" timeout="${3:-3600}" elapsed=0
  info "waiting for InferenceService ${name} (first model pull is the slow part)"
  while (( elapsed < timeout )); do
    local ready
    ready="$(oc get inferenceservice "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${ready}" == "True" ]]; then
      info "model is serving"; return 0
    fi

    # An init container in backoff never recovers. Fail now rather than burning
    # the full timeout on something already dead.
    if oc get pods -n "${ns}" -l component=predictor \
         -o jsonpath='{.items[*].status.initContainerStatuses[*].state.waiting.reason}' 2>/dev/null \
         | grep -q 'ImagePullBackOff\|ErrImagePull\|CrashLoopBackOff'; then
      warn "predictor init container is in backoff, this will not recover"
      oc describe pod -n "${ns}" -l component=predictor | tail -15
      return 1
    fi

    # No pod after a couple of minutes CAN mean the InferenceService cannot
    # reconcile, usually an invalid ServingRuntime such as an empty image.
    #
    # But KServe also hits transient status-update conflicts right after
    # creation ("the object has been modified; please apply your changes to the
    # latest version"), and those resolve on the next reconcile. Absence of a
    # pod is therefore not enough to give up on: look for a TERMINAL error and
    # keep waiting otherwise.
    if (( elapsed >= 120 )) && \
       [[ -z "$(oc get pods -n "${ns}" -l component=predictor -o name 2>/dev/null)" ]]; then
      local fatal
      fatal="$(oc get events -n "${ns}" \
        -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null \
        | grep -E 'is invalid|Required value|Forbidden|no matches for kind' \
        | tail -1 || true)"
      if [[ -n "${fatal}" ]]; then
        warn "the InferenceService cannot reconcile:"
        warn "  ${fatal}"
        return 1
      fi
      (( elapsed % 120 == 0 )) && \
        warn "no predictor pod yet after ${elapsed}s (KServe may be retrying), still waiting"
    fi

    # A Pending pod beside a Running one is a rolling update deadlocked on a
    # single GPU, not a failure to start. The model works; say so.
    if [[ -n "$(oc get pods -n "${ns}" -l component=predictor \
           --field-selector status.phase=Running -o name 2>/dev/null)" ]] && \
       [[ -n "$(oc get pods -n "${ns}" -l component=predictor \
           --field-selector status.phase=Pending -o name 2>/dev/null)" ]]; then
      warn "an older predictor is serving while a new one waits for the GPU."
      warn "the model works, but the rolling update cannot complete on one GPU."
      warn "clear the stale ReplicaSet, or check deploymentStrategy is Recreate."
      return 0
    fi

    sleep 20; elapsed=$((elapsed+20))
    (( elapsed % 60 == 0 )) && info "  still waiting (${elapsed}s)"
  done
  warn "InferenceService did not become Ready in ${timeout}s"
  warn "check: oc get pods -n ${ns} -l component=predictor"
  warn "fallback: set AI_BACKEND=ollama in demo.env and re-run scripts/up.sh"
  return 1
}

wait_for_gitlab() {
  local ns="$1" timeout="${2:-3600}" elapsed=0
  info "waiting for GitLab to reconcile (first run is genuinely slow)"
  while (( elapsed < timeout )); do
    local phase
    phase="$(oc get gitlab gitlab -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Running" ]]; then
      info "GitLab is Running"; return 0
    fi
    # Webservice ready is the practical signal; the CR status can lag behind it.
    if [[ "$(oc get deployment gitlab-webservice-default -n "${ns}" \
         -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" =~ ^[1-9] ]]; then
      info "webservice is ready"; return 0
    fi
    sleep 30; elapsed=$((elapsed+30))
    if (( elapsed % 120 == 0 )); then
      info "  still waiting (${elapsed}s, phase: ${phase:-pending})"
      # Surface a stuck reconcile rather than sitting quietly through it. A
      # missing CRD loops here forever with no clue why, which cost two days.
      local err
      err="$(oc logs -n "${ns}" deployment/gitlab-controller-manager --tail=3 2>/dev/null \
        | grep -o 'no matches for kind [^"]*' | tail -1 || true)"
      [[ -n "${err}" ]] && warn "operator is stuck: ${err}"
    fi
  done
  warn "GitLab did not come up in ${timeout}s"
  warn "check: oc get pods -n ${ns}"
  warn "and:   oc logs -n ${ns} deployment/gitlab-controller-manager --tail=20"
  return 1
}

# --- discovery --------------------------------------------------------------

# Read the vLLM runtime image from the cluster's own template. RHOAI ships
# runtime images matched to its version, so discovering beats pinning: a
# mismatched runtime fails deep inside vLLM startup, after an 18GB pull, with an
# error that reads like a model problem rather than a version problem. The
# digest also differs between environments.
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

# The GitLab operator accepts only the chart versions it ships, and that list
# moves with each operator release: 10.3.1 on one environment, 10.4.0 three
# weeks later. It rejects anything else at admission and names the valid ones in
# the error, which is the ONLY way it exposes them.
#
# So submit a deliberately invalid version and read the list back. Slightly
# cheeky, but it beats discovering it 40 minutes into a bring-up, and it means
# this repo keeps working as the operator moves.
#
# Requires the operator's CRD to exist, so call it after the Subscription.
discover_gitlab_chart_version() {
  local out ver
  out="$(oc apply --dry-run=server -f - 2>&1 <<EOS || true
apiVersion: apps.gitlab.com/v1beta1
kind: GitLab
metadata:
  name: chart-version-probe
  namespace: ${GITLAB_NAMESPACE}
spec:
  chart:
    version: "0.0.0-probe"
EOS
)"
  ver="$(grep -o 'following:[^"]*' <<< "${out}" \
    | sed 's/following://' | tr ',' '\n' | head -1 | tr -d ' \n')"
  [[ -n "${ver}" ]] || return 1
  echo "${ver}"
}

# Is this chart version one the operator will accept? Used to validate a value
# left in demo.env, which on a new environment is stale more often than not.
chart_version_accepted() {
  local v="$1" out
  out="$(oc apply --dry-run=server -f - 2>&1 <<EOS || true
apiVersion: apps.gitlab.com/v1beta1
kind: GitLab
metadata:
  name: chart-version-probe
  namespace: ${GITLAB_NAMESPACE}
spec:
  chart:
    version: "${v}"
EOS
)"
  ! grep -q 'not supported' <<< "${out}"
}

# --- Images -----------------------------------------------------------------

# Does this image reference resolve?
#
# ALWAYS GO THROUGH THIS, never bare `oc image info`. A multi-arch image is a
# manifest list, and plain `oc image info` REFUSES one:
#
#   error: the image is a manifest list and contains multiple images
#          - use --filter-by-os to select from: linux/amd64, linux/arm64
#
# That is a non-zero exit on a perfectly good image, which reads as a missing
# tag. Harmless where the caller only warns; a false hard failure on the
# ModelCar check, which is the one place this script stops a run.
#
# linux/amd64 is deliberate rather than a default: these clusters are amd64, so
# an image published only for arm64 genuinely cannot run here and SHOULD fail.
image_resolves() {
  oc image info --filter-by-os=linux/amd64 "$1" >/dev/null 2>&1
}

# --- GPU --------------------------------------------------------------------

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

  # Count only GPUs held OUTSIDE the demo namespace. Our own predictor
  # legitimately holds one once the model is serving, and counting it would make
  # this check fail precisely when everything is working.
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
    warn "See what is holding them:  ./scripts/gpu-claims.sh"
    warn ""
    warn "Then scale down or delete the pre-existing workload, or set"
    warn "AI_BACKEND=ollama in demo.env if you would rather not touch it."
    return 1
  fi
}

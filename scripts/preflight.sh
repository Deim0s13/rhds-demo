#!/usr/bin/env bash
# Validate everything checkable in seconds, BEFORE committing to a bring-up that
# takes the better part of an hour.
#
# Run this first on every new environment. Nearly every failure this repo has
# had was detectable up front: a chart version the operator no longer accepts, a
# registry that went private overnight, a ModelCar tag that moved, an empty
# variable rendering into a manifest, a fix that did not save. Each cost 25 to 90
# minutes to discover the slow way.
#
#   ./scripts/preflight.sh && ./scripts/up.sh 2>&1 | tee up-$(date +%H%M).log
set -uo pipefail   # deliberately not -e: every check should run

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"

FAILED=0
WARNED=0
ok()   { printf '    [ ok ] %s\n' "$*"; }
bad()  { printf '\033[1;31m    [fail] %s\033[0m\n' "$*"; FAILED=$((FAILED+1)); }
soft() { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; WARNED=$((WARNED+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

banner "Tooling"
for t in oc git curl python3 openssl sed awk bc; do
  check "${t} on PATH" "command -v ${t}"
done

banner "Cluster access"
if oc whoami >/dev/null 2>&1; then
  ok "logged in as $(oc whoami) on $(oc whoami --show-server)"
else
  bad "not logged in. oc login --token=... --server=..."
  echo; echo "    Cannot continue without a cluster."; exit 1
fi

banner "Configuration"
if [[ -f "${REPO_ROOT}/demo.env" ]]; then
  ok "demo.env present"
else
  bad "demo.env missing. cp demo.env.example demo.env"
  exit 1
fi

if [[ -f "${REPO_ROOT}/.demo-secrets" ]]; then
  bad ".demo-secrets is in the working tree. It must not be. rm ${REPO_ROOT}/.demo-secrets"
else
  ok "no credentials file inside the repository"
fi

# load_env calls load_or_generate_secrets and the discovery helpers, so from
# here on every variable is populated exactly as up.sh will see it.
load_env >/dev/null 2>&1 || { bad "load_env failed, check demo.env"; exit 1; }
ok "configuration loaded (backend: ${AI_BACKEND}, GitLab: ${DEPLOY_GITLAB})"

banner "Script integrity"
# These are fixes that have gone missing between edits more than once. Cheaper to
# assert here than to rediscover 40 minutes into a run.
while IFS='|' read -r f pat desc; do
  [[ -z "${f}" ]] && continue
  if grep -q -- "${pat}" "${REPO_ROOT}/scripts/${f}" 2>/dev/null; then
    ok "${f}: ${desc}"
  else
    bad "${f}: ${desc} MISSING"
  fi
done <<'ROWS'
lib.sh|refusing to apply|render placeholder guard
lib.sh|but their value is empty|render empty-value guard
lib.sh|discover_vllm_image|vLLM runtime discovery
lib.sh|discover_gitlab_chart_version|chart version discovery
lib.sh|chart_version_accepted|chart version validation
lib.sh|filter-by-os|manifest-list safe image resolution
lib.sh|load_or_generate_secrets|credentials kept outside the repo
lib.sh|free_gpu_if_safe|GPU allow-list handling
up.sh|server-side|Envoy CRD server-side apply
up.sh|condition=established|Envoy CRD establish wait
up.sh|discovering vLLM|runtime discovery wired in
up.sh|control-plane=controller-manager|operator cache refresh
up.sh|creating object storage buckets|bucket exec loop (not the hanging Job)
seed-gitlab.sh|timeout 240|bounded token mint
seed-gitlab.sh|GITLAB_TOKEN|token override
ROWS

# The Job version of bucket creation hangs indefinitely. Assert it is gone.
if grep -q 'gitlab-s3-buckets' "${REPO_ROOT}/scripts/up.sh" 2>/dev/null; then
  bad "up.sh still references the gitlab-s3-buckets Job, which hangs forever"
else
  ok "up.sh: hanging bucket Job removed"
fi
if [[ -f "${REPO_ROOT}/overlays/gitlab/00-minio.yaml" ]]; then
  bad "overlays/gitlab/00-minio.yaml still present. MinIO's registries are gated; delete it"
else
  ok "no stale MinIO manifest"
fi

# The prepull DaemonSet exists to warm the exact image the workspace will use.
# If the two drift, the prepull succeeds, preflight stays green, and act 6 pulls
# a multi-gigabyte image cold in front of the room. Nothing else catches this.
adt_devfile="$(grep -o 'community-ansible-dev-tools:[^ ]*' \
  "${REPO_ROOT}/samples/ansible-automation/devfile.yaml" 2>/dev/null | head -1)"
adt_prepull="$(grep -o 'community-ansible-dev-tools:[^ ]*' \
  "${REPO_ROOT}/bootstrap/06-image-prepull.yaml" 2>/dev/null | head -1)"
if [[ -z "${adt_devfile}" || -z "${adt_prepull}" ]]; then
  bad "could not find the ansible dev tools image in both the devfile and the prepull"
elif [[ "${adt_devfile}" != "${adt_prepull}" ]]; then
  bad "ansible image mismatch: devfile ${adt_devfile}, prepull ${adt_prepull}"
else
  ok "ansible image consistent: ${adt_devfile}"
fi

banner "Manifests parse"
while IFS= read -r m; do
  if python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" "${m}" 2>/dev/null; then
    ok "${m#"${REPO_ROOT}"/}"
  else
    bad "${m#"${REPO_ROOT}"/} does not parse as YAML"
  fi
done < <(find "${REPO_ROOT}/bootstrap" "${REPO_ROOT}/overlays" -name '*.yaml' 2>/dev/null | sort)

banner "Devfiles"
for d in payments-service ansible-automation; do
  f="${REPO_ROOT}/samples/${d}/devfile.yaml"
  if python3 -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
assert d['schemaVersion'].startswith('2.'), 'schemaVersion'
for p in d.get('projects',[]):
    assert 'subDir' not in p, 'subDir is not valid in schema 2.2.0'
" "${f}" 2>/dev/null; then
    ok "${d}/devfile.yaml"
  else
    bad "${d}/devfile.yaml invalid (check subDir, schemaVersion)"
  fi
done
if [[ -f "${REPO_ROOT}/samples/ledger-service/devfile.yaml" ]]; then
  bad "ledger-service has a devfile. It must NOT: act 5 authors one live"
else
  ok "ledger-service is devfile-free, as act 5 requires"
fi

banner "GitLab CR structure"
# YAML nesting errors pass every validator: the document parses, the CRD accepts
# it, the operator renders it, and the value simply is not where you meant it.
# gatewayApi nested inside ingress instead of beside it cost four cycles.
if python3 -c "
import yaml
d=yaml.safe_load(open('${REPO_ROOT}/overlays/gitlab/02-gitlab.yaml'))
g=d['spec']['chart']['values']['global']
assert 'gatewayApi' in g, 'gatewayApi not under global'
assert 'gatewayApi' not in g.get('ingress',{}), 'gatewayApi wrongly nested inside ingress'
assert g['appConfig']['object_store']['connection']['key']=='config', 'object_store key must be config'
" 2>/dev/null; then
  ok "gatewayApi is a sibling of ingress, object_store key is 'config'"
else
  bad "GitLab CR structure is wrong. Run the python check in that file's comments."
fi

banner "Rendering"
# The highest-value check. Renders every manifest exactly as up.sh will, with
# runtime discovery already done, and fails on any placeholder with no rule OR an
# empty value. This is what catches an empty image reference in seconds instead
# of as InvalidImageName half an hour later.
if [[ "${AI_BACKEND}" == "rhoai" && -z "${AI_RUNTIME_IMAGE}" ]]; then
  AI_RUNTIME_IMAGE="$(discover_vllm_image 2>/dev/null || true)"
  if [[ -n "${AI_RUNTIME_IMAGE}" ]]; then
    ok "vLLM runtime discovered: ...${AI_RUNTIME_IMAGE: -20}"
  else
    bad "no vllm-cuda runtime template in ${RHOAI_NAMESPACE}. Is RHOAI installed?"
  fi
fi
GITLAB_HOST="${GITLAB_HOST:-gitlab.${CLUSTER_APPS_DOMAIN}}"
USER_NAMESPACE="${USER_NAMESPACE:-preflight-placeholder}"
# Chart version is discovered after the operator installs, so stub it here.
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-0.0.0-preflight}"

while IFS= read -r m; do
  rel="${m#"${REPO_ROOT}"/}"
  [[ "${rel}" == *"/ollama/"* && "${AI_BACKEND}" != "ollama" ]] && continue
  [[ "${rel}" == *"/rhoai/"*  && "${AI_BACKEND}" != "rhoai"  ]] && continue
  [[ "${rel}" == *"/gitlab/"* && "${DEPLOY_GITLAB}" != "true" ]] && continue
  if render "${m}" >/dev/null 2>&1; then
    ok "renders clean: ${rel}"
  else
    bad "unresolved or empty placeholders: ${rel}"
    render "${m}" 2>&1 >/dev/null | sed 's/^/           /'
  fi
done < <(find "${REPO_ROOT}/bootstrap" "${REPO_ROOT}/overlays" -name '*.yaml' 2>/dev/null | sort)

banner "External images"
# WARNINGS, NOT FAILURES, and this distinction matters.
#
# oc image info runs from YOUR LAPTOP, not the cluster. Your local client
# usually has no registry credentials, so registry.redhat.io,
# registry.access.redhat.com, docker.io and ghcr.io all report "unauthorized"
# even for images the cluster pulls perfectly well with its own pull secret.
# quay.io tends to answer anonymously, which is why it looks inconsistent.
#
# Treating these as hard failures produced seven bogus errors on a healthy
# cluster, which is the fastest way to teach someone to ignore preflight.
#
# To make this authoritative for the Red Hat registries:
#   oc registry login --registry registry.redhat.io
# Or check from the cluster itself, which is what actually matters:
#   oc run imgcheck --restart=Never --image=<ref> -- sleep 10
#   oc get pod imgcheck    # ImagePullBackOff means genuinely unreachable
IMAGES="$(find "${REPO_ROOT}/bootstrap" "${REPO_ROOT}/overlays" -name '*.yaml' -exec \
  grep -h '^[[:space:]]*image:' {} \; 2>/dev/null \
  | sed 's/.*image:[[:space:]]*//' | tr -d '"' | grep -v PLACEHOLDER | sort -u)"
if [[ -z "${IMAGES}" ]]; then
  soft "no static image references found"
else
  unresolved=0
  while IFS= read -r img; do
    [[ -z "${img}" ]] && continue
    if image_resolves "${img}"; then
      ok "${img}"
    else
      soft "could not resolve ${img} from here (likely a local credential gap)"
      unresolved=$((unresolved+1))
    fi
  done <<< "${IMAGES}"
  if (( unresolved > 0 )); then
    soft ""
    soft "${unresolved} image(s) unresolved from this client. That is usually a"
    soft "missing local pull secret, not a missing image. The cluster has its own."
    soft "If a pod later reports ImagePullBackOff, THAT is the real signal."
  fi
fi

if [[ "${AI_BACKEND}" == "rhoai" ]]; then
  # This one IS a hard failure. The ModelCar catalogue is on quay.io, which
  # answers anonymously, so a failure here is genuinely a moved tag, and a
  # moved tag fails minutes later in an init container rather than at apply.
  if image_resolves "${AI_MODEL_IMAGE#oci://}"; then
    ok "ModelCar ${AI_MODEL_IMAGE#oci://}"
  else
    bad "cannot resolve ModelCar ${AI_MODEL_IMAGE}. Catalogue tags move."
  fi
fi

banner "Unpinned references"
# Not all :latest tags are equal.
#
# registry.redhat.io/rhel9/postgresql-16:latest and ubi9/openjdk-21:latest
# already pin the MAJOR version in the repository name. Red Hat rebuilds those
# for CVEs, and taking the rebuild is what you want: it is the same argument
# act 3 makes about patched base images. Leaving these floating is deliberate.
#
# A community image with no version in its name is a different matter. That can
# change behaviour overnight with nothing in the repo changing, which is how
# MinIO broke this demo.
while IFS= read -r l; do
  [[ -z "${l}" ]] && continue
  rel="${l#"${REPO_ROOT}"/}"
  if grep -qE 'redhat\.(io|com)/(rhel9|ubi9)/[a-z]+-?[0-9]+:latest|ubi9/ubi-minimal:latest' <<< "${l}"; then
    ok "floating by design (Red Hat, major version pinned in the name): ${rel##*/}"
  else
    soft "genuinely unpinned, consider a version: ${rel}"
  fi
done < <(find "${REPO_ROOT}/bootstrap" "${REPO_ROOT}/overlays" -name '*.yaml' -exec \
  grep -Hn 'image:.*:latest' {} \; 2>/dev/null || true)

if [[ "${DEPLOY_GITLAB}" == "true" ]]; then
  banner "GitLab prerequisites"
  check "Envoy Gateway ${ENVOY_GATEWAY_VERSION} manifest reachable" \
    "curl -fsSL -o /dev/null --max-time 25 https://github.com/envoyproxy/gateway/releases/download/${ENVOY_GATEWAY_VERSION}/install.yaml"

  if oc get crd gitlabs.apps.gitlab.com >/dev/null 2>&1; then
    v="$(discover_gitlab_chart_version 2>/dev/null || true)"
    if [[ -n "${v}" ]]; then
      ok "operator accepts chart version ${v} (newest offered)"
    else
      soft "could not read the accepted chart version list from the operator"
    fi
  else
    soft "GitLab operator not installed yet, cannot check chart version"
    soft "  expected on a fresh cluster. up.sh installs it and discovers the version."
  fi
fi

if [[ "${AI_BACKEND}" == "rhoai" ]]; then
  banner "GPU and RHOAI"
  check "RHOAI namespace present" "oc get ns ${RHOAI_NAMESPACE}"
  check "KServe CRDs present"     "oc get crd inferenceservices.serving.kserve.io"
  if check_gpu_capacity >/dev/null 2>&1; then
    ok "a GPU is available to us"
  else
    soft "no free GPU. up.sh clears known RHDP sample namespaces automatically;"
    soft "  run ./scripts/gpu-claims.sh to see what is holding it"
  fi
fi

banner "Result"
if (( FAILED > 0 )); then
  printf '\033[1;31m    %d check(s) failed, %d warning(s).\033[0m\n\n' "${FAILED}" "${WARNED}"
  printf '    Fix these before running up.sh. Each becomes a much slower failure\n'
  printf '    once the bring-up is underway.\n\n'
  exit 1
fi
printf '\033[1;32m    All checks passed'
(( WARNED > 0 )) && printf ', %d warning(s)' "${WARNED}"
printf '.\033[0m\n\n'
printf '    ./scripts/up.sh 2>&1 | tee up-$(date +%%H%%M).log\n\n'

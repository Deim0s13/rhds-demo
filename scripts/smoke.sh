#!/usr/bin/env bash
# Pre-flight. Run this at least 30 minutes before you present.
# Its whole job is to make the first image pull happen when nobody is watching.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login

FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf '    [ ok ] %s\n' "$1"
  else printf '\033[1;31m    [fail] %s\033[0m\n' "$1"; FAIL=1; fi
}

banner "Cluster state"
check "Dev Spaces operator installed"   "oc get csv -n openshift-operators | grep -qi 'devspaces.*Succeeded'"
check "CheCluster is Active"            "[[ \$(oc get checluster devspaces -n ${DEVSPACES_NAMESPACE} -o jsonpath='{.status.chePhase}') == Active ]]"
check "Dashboard route resolves"        "oc get checluster devspaces -n ${DEVSPACES_NAMESPACE} -o jsonpath='{.status.cheURL}' | grep -q https"
check "Demo namespace exists"           "oc get ns ${DEMO_NAMESPACE}"
case "${AI_BACKEND}" in
  rhoai)
    check "RHOAI installed"              "oc get ns ${RHOAI_NAMESPACE}"
    check "GPU allocatable on a node"    "oc get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\\.com/gpu}' | grep -q '[1-9]'"
    check "InferenceService Ready"       "[[ \$(oc get inferenceservice ${AI_SERVICE_NAME} -n ${DEMO_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}') == True ]]"
    check "Model answers a completion"   "oc run smoke-ai-\$RANDOM -n ${DEMO_NAMESPACE} --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -- curl -sf -m 60 -X POST ${AI_BASE_URL}/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"${AI_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":5}'"
    ;;
  ollama)
    check "Model deployment ready"       "oc get deployment ${AI_SERVICE_NAME} -n ${DEMO_NAMESPACE} -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    check "Model ${OLLAMA_MODEL} pulled" "oc exec -n ${DEMO_NAMESPACE} deployment/${AI_SERVICE_NAME} -- ollama list | grep -q '${OLLAMA_MODEL%%:*}'"
    ;;
  none)
    info "    [skip] AI backend is 'none'"
    ;;
esac

banner "Devfile drift"
if [[ -n "${AI_BASE_URL}" ]]; then
  check "Committed devfile matches AI_BASE_URL" \
    "grep -q '${AI_BASE_URL}' ${REPO_ROOT}/samples/spring-boot-app/devfile.yaml"
  info "if that failed: run scripts/render-devfiles.sh, then commit and push"
fi

banner "Warming images"
info "Pre-pulling workspace images onto every worker node."
info "Cold pulls in front of a customer are the number one cause of a dead demo."
render "${REPO_ROOT}/bootstrap/06-image-prepull.yaml" | oc apply -f - 2>/dev/null || \
  warn "prepull DaemonSet manifest missing, skipping"
sleep 5
oc rollout status daemonset/devspaces-image-prepull -n "${DEMO_NAMESPACE}" --timeout=900s 2>/dev/null \
  || warn "prepull did not complete, first workspace start will be slower"

banner "Manual steps you still have to do yourself"
cat <<'MSG'
    1. Open the dashboard and start the Spring Boot workspace once. Leave it running.
    2. Connect your desktop VS Code to it once, and your JetBrains client once.
       Both need to have been paired before, or you will be doing OAuth on stage.
    3. Confirm the AI assistant returns a completion in the browser IDE.
    4. Run scripts/reset.sh afterwards to put the samples back to their start state.
MSG

exit ${FAIL}

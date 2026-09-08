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
check "Dev Spaces operator installed"   "oc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.status.phase}{\"\\n\"}{end}' | grep -qi 'devspaces.*Succeeded'"
check "CheCluster is Active"            "[[ \$(oc get checluster devspaces -n ${DEVSPACES_NAMESPACE} -o jsonpath='{.status.chePhase}') == Active ]]"
check "Dashboard route resolves"        "oc get checluster devspaces -n ${DEVSPACES_NAMESPACE} -o jsonpath='{.status.cheURL}' | grep -q https"
check "Demo namespace exists"           "oc get ns ${DEMO_NAMESPACE}"
case "${AI_BACKEND}" in
  rhoai)
    check "RHOAI installed"              "oc get ns ${RHOAI_NAMESPACE}"
    check "GPU present and not fully claimed" "check_gpu_capacity"
    check "InferenceService Ready"       "[[ \$(oc get inferenceservice ${AI_SERVICE_NAME} -n ${DEMO_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}') == True ]]"
    # Exec into the predictor itself. Spawning a ubi-minimal pod does not work:
    # that image has no curl, so the check could never pass.
    check "Model answers a completion"   "oc exec -n ${DEMO_NAMESPACE} deployment/coder-model-predictor -c kserve-container -- python3 -c \"
import json,urllib.request
r=urllib.request.urlopen(urllib.request.Request('http://localhost:8080/v1/chat/completions',
  data=json.dumps({'model':'${AI_MODEL}','messages':[{'role':'user','content':'ok'}],'max_tokens':5}).encode(),
  headers={'Content-Type':'application/json'}),timeout=60)
assert r.status==200\""
    ;;
  ollama)
    check "Model deployment ready"       "oc get deployment ${AI_SERVICE_NAME} -n ${DEMO_NAMESPACE} -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
    check "Model ${OLLAMA_MODEL} pulled" "oc exec -n ${DEMO_NAMESPACE} deployment/${AI_SERVICE_NAME} -- ollama list | grep -q '${OLLAMA_MODEL%%:*}'"
    ;;
  none)
    info "    [skip] AI backend is 'none'"
    ;;
esac

if [[ "${DEPLOY_GITLAB}" == "true" ]]; then
  banner "Internal Git"
  check "GitLab webservice ready"      "oc get deployment gitlab-webservice-default -n ${GITLAB_NAMESPACE} -o jsonpath='{.status.readyReplicas}' | grep -q '^[1-9]'"
  check "Route resolves"               "curl -sk -o /dev/null -w '%{http_code}' https://${GITLAB_HOST}/users/sign_in | grep -q 200"
  for r in payments-service ansible-automation ledger-service; do
    check "Project ${r} seeded"        "curl -sk -o /dev/null -w '%{http_code}' https://${GITLAB_HOST}/${GITLAB_GROUP}/${r} | grep -q 200"
  done
  # The devfile must be fetchable at the raw path AND carry a rendered endpoint.
  check "payments devfile is rendered" \
    "curl -sk https://${GITLAB_HOST}/${GITLAB_GROUP}/payments-service/-/raw/main/devfile.yaml | grep -q 'AI_BASE_URL' && ! curl -sk https://${GITLAB_HOST}/${GITLAB_GROUP}/payments-service/-/raw/main/devfile.yaml | grep -q 'PLACEHOLDER'"

  banner "Dev Spaces SCM wiring"
  # Without these two, Dev Spaces cannot resolve a devfile from GitLab and
  # falls back to offering a default one, which then fails to start.
  check "GitLab registered in CheCluster" \
    "oc get checluster devspaces -n ${DEVSPACES_NAMESPACE} -o jsonpath='{.spec.gitServices.gitlab[0].endpoint}' | grep -q '${GITLAB_HOST}'"
  check "OAuth secret present"         "oc get secret gitlab-oauth-config -n ${DEVSPACES_NAMESPACE}"
  check "Cluster CA trusted"           "oc get configmap cluster-ca-bundle -n ${DEVSPACES_NAMESPACE}"
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

#!/usr/bin/env bash
# Show what is currently holding the GPUs, and how to release them.
#
# RHOAI demo environments are usually provisioned with a sample model already
# being served. That workload holds the GPU, so your InferenceService sits
# Pending. This script tells you what to remove.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login
assert_provisioned_cluster

banner "GPU capacity by node"
oc get nodes -o custom-columns=\
'NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu' | grep -v '<none>' || true

banner "Pods requesting a GPU"
oc get pods --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' \
  | awk -F'\t' '$4 != "" {printf "  %-28s %-45s %-10s %s\n", $1, $2, $3, $4}'

banner "InferenceServices on this cluster"
oc get inferenceservice --all-namespaces 2>/dev/null \
  || info "none, or KServe CRDs not present"

banner "Notebooks (a common GPU holder on RHOAI environments)"
oc get notebooks --all-namespaces 2>/dev/null || info "none"

banner "How to release one"
cat <<'MSG'
    Prefer scaling down over deleting. It is reversible, and if this environment
    is shared you have not destroyed someone else's work.

    A pre-existing InferenceService:
      oc patch inferenceservice <name> -n <ns> \
        --type merge -p '{"spec":{"predictor":{"minReplicas":0}}}'

    Or remove it outright:
      oc delete inferenceservice <name> -n <ns>

    A notebook / workbench:
      oc patch notebook <name> -n <ns> --type merge \
        -p '{"metadata":{"annotations":{"kubeflow-resource-stopped":"true"}}}'

    A plain deployment:
      oc scale deployment/<name> -n <ns> --replicas=0

    Then confirm the GPU is free and re-run:
      ./scripts/gpu-claims.sh
      ./scripts/up.sh

    Note the pod can take a minute to terminate and release the device. If the
    scheduler still will not place your predictor, wait and check again before
    assuming something else is wrong.
MSG

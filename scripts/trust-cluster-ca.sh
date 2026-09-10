#!/usr/bin/env bash
# Teach Dev Spaces to trust the cluster's default ingress certificate.
#
# Workspaces and the Che server both need this before they can talk to an
# internal SCM served by an OpenShift Route. Without it you get a TLS error
# when creating a workspace, and it reads like a GitLab problem rather than a
# trust problem, which is a bad half hour.
#
# In a bank this is the corporate CA rather than the cluster's self-signed one,
# but the mechanism is identical and it is worth saying so in act 3.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env; require oc; require_login

banner "Adding the cluster CA to the Dev Spaces trust bundle"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

oc get configmap default-ingress-cert -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' > "${TMP}/ca.crt"
[[ -s "${TMP}/ca.crt" ]] || die "could not read the cluster ingress CA"

info "creating the trust bundle ConfigMap"
oc create configmap cluster-ca-bundle \
  -n "${DEVSPACES_NAMESPACE}" \
  --from-file=ca.crt="${TMP}/ca.crt" \
  --dry-run=client -o yaml | oc apply -f -

# This label is what Dev Spaces watches for. Certificates in any ConfigMap
# carrying it are mounted into the Che server and into every workspace.
oc label configmap cluster-ca-bundle -n "${DEVSPACES_NAMESPACE}" \
  app.kubernetes.io/part-of=che.eclipse.org \
  app.kubernetes.io/component=ca-bundle \
  --overwrite

info "restarting the Che server to pick it up"
oc rollout restart deployment/devspaces -n "${DEVSPACES_NAMESPACE}" 2>/dev/null || true
oc rollout status deployment/devspaces -n "${DEVSPACES_NAMESPACE}" --timeout=300s 2>/dev/null || true

cat <<MSG

    Done. Any workspace started from now on trusts the cluster CA.

    Workspaces already running will not: restart them.

MSG

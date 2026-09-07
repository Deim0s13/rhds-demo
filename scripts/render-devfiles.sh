#!/usr/bin/env bash
# Devfiles are fetched by Dev Spaces directly from Git, so unlike the bootstrap
# manifests they cannot carry placeholders resolved at apply time. This script
# rewrites the AI endpoint values in the committed devfiles from demo.env.
#
# Run it after changing AI_BACKEND, AI_MODEL, AI_SERVICE_NAME or DEMO_NAMESPACE,
# then COMMIT AND PUSH. A workspace started from an unpushed devfile will use
# whatever is in Git, not what is on your laptop.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib.sh"
load_env

DEVFILES=(
  "${REPO_ROOT}/samples/spring-boot-app/devfile.yaml"
  "${REPO_ROOT}/samples/ansible-workspace/devfile.yaml"
)

if [[ -z "${AI_BASE_URL}" ]]; then
  warn "AI_BACKEND is '${AI_BACKEND}', so there is no endpoint to render."
  warn "Devfiles left unchanged. The AI segment of act 6 will not work."
  exit 0
fi

banner "Rendering AI endpoint into devfiles"
info "backend : ${AI_BACKEND}"
info "endpoint: ${AI_BASE_URL}"
info "model   : ${AI_MODEL}"

for f in "${DEVFILES[@]}"; do
  [[ -f "${f}" ]] || { warn "missing ${f}"; continue; }
  python3 - "${f}" "${AI_BASE_URL}" "${AI_MODEL}" <<'PY'
import re, sys
path, base_url, model = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
src, n1 = re.subn(r'(- name: AI_BASE_URL\n\s+value: ")[^"]*(")',
                  lambda m: m.group(1) + base_url + m.group(2), src)
src, n2 = re.subn(r'(- name: AI_MODEL\n\s+value: ")[^"]*(")',
                  lambda m: m.group(1) + model + m.group(2), src)
open(path, 'w').write(src)
print(f"    updated {path} (base_url: {n1}, model: {n2})")
PY
done

banner "Next"
cat <<'MSG'
    git add samples/*/devfile.yaml
    git commit -m "Point workspaces at the current inference endpoint"
    git push

    Workspaces read the devfile from Git. If you skip the push, the demo will
    silently use the previous endpoint and the assistant will time out on stage.
MSG

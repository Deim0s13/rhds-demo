# Choosing the AI Backend

Act 6 needs a model. The workspace only ever needs an OpenAI-compatible base
URL, so the backend is a variable in `demo.env`, not a fork of the demo.

## Which one, when

|                    | `rhoai`                            | `ollama`                                |
| ------------------ | ---------------------------------- | --------------------------------------- |
| Environment needed | RHOAI with GPU                     | any OpenShift                           |
| Adds to bootstrap  | 15 to 25 min                       | about 5 min                             |
| Model              | 3B on GPU, genuinely responsive    | 1.5B on CPU, adequate                   |
| Best for           | risk, security, EA, platform teams | app developers, tight timings, fallback |

**Default to `rhoai` when you have the environment and the room contains anyone
who owns risk or architecture.** The reason is not model quality. It is that an
InferenceService served by a model serving team, consumed by a development team,
is the actual enterprise shape. It gives you a genuine separation of concerns to
point at in act 7: someone owns the model, someone owns serving, someone owns the
workspace stack, and they are three different teams with three different approval
paths.

**Fall back to `ollama` without embarrassment.** If the GPU environment is late,
if the InferenceService is still pulling weights twenty minutes before you start,
or if you are simply running to time, change one variable. The argument you are
making about where inference happens does not depend on which backend serves it.

## Running the RHOAI path

```bash
# demo.env
AI_BACKEND="rhoai"
AI_MODEL="llama-3.2-3b-instruct"
AI_SERVICE_NAME="coder-model"
AI_MODEL_IMAGE="oci://quay.io/redhat-ai-services/modelcar-catalog:llama-3.2-3b-instruct"
AI_RUNTIME_IMAGE=""     # leave empty: discovered from the cluster
```

`preflight.sh` validates the ModelCar reference and resolves the runtime image
before `up.sh` commits to anything.

### Do not pin the runtime image

RHOAI ships vLLM runtime images matched to its own version, and the digest
differs between environments: `ba060ec1...` on one cluster, `c056e616...` three
weeks later. `discover_vllm_image` reads it from the cluster's
`vllm-cuda-runtime-template`.

A pinned guess fails deep inside vLLM startup, _after_ an 18GB pull, with a
tokeniser attribute error that reads like a model problem rather than a version
problem. That cost most of a day.

### Confirm the ModelCar tag

The other thing most likely to bite. Catalogue tags move, and a bad reference
does not fail at `oc apply`; it fails minutes later in an init container.

```bash
oc image info --filter-by-os=linux/amd64 \
  quay.io/redhat-ai-services/modelcar-catalog:<tag>
```

`--filter-by-os` is not optional. Without it, a multi-arch image makes
`oc image info` exit non-zero with "the image is a manifest list", which reads
exactly like a missing tag. The scripts go through `image_resolves` in `lib.sh`
for this reason.

If your environment has an internal mirror, point `AI_MODEL_IMAGE` at that. In a
bank that is the only acceptable answer anyway, and it is worth saying live:
model weights are a supply chain artefact and belong under the same registry
controls as your base images. That connects straight back to the act 3 point.

### The GPU is probably already in use

RHOAI environments commonly arrive with a sample model already served, holding
the GPU. `up.sh` deletes namespaces on the `RHDP_SAMPLE_NAMESPACES` allow-list,
and only those, when they actually hold a GPU. Anything else gets a warning and
is left alone, so the script stays safe on a shared cluster.

`./scripts/gpu-claims.sh` is read-only and shows what is holding what. Set
`FREE_GPU="false"` on any cluster you did not personally provision.

Allow a minute after scaling something down: the pod must terminate before the
device plugin releases the GPU, and the scheduler will not place your predictor
until it does. Do not conclude something else is broken in that window.

### Why `--max-model-len=8192`

Llama 3.2 advertises 131k context. vLLM v1 sizes the KV cache to serve one
request at full length, needs 14.0 GiB, and finds 13.41 available, so engine
initialisation fails. Code completion sends a few hundred tokens of surrounding
file, so 8k is generous.

This is also the honest answer to "how many developers can one GPU serve". The
constraint is the KV cache, which scales with context length times concurrent
requests, not the model weights. Offer to size it properly with their numbers
rather than inventing a figure in the room.

## How the workspace actually reaches the model

Two pieces, and both must be present. Setting `AI_BASE_URL` alone does nothing.

1. `.vscode/extensions.json` lists `Continue.continue`, which Dev Spaces installs
   from Open VSX at workspace startup.
2. The `configure-ai` command runs on `postStart` and writes
   `~/.continue/config.yaml` from `AI_BASE_URL`, `AI_MODEL` and `AI_API_KEY` in
   the container environment.

Reading the values from the environment at runtime rather than from rendered
placeholders keeps one source of truth, so overriding `AI_BASE_URL` takes effect
without re-seeding.

`smoke.sh` checks for both. Without them the workspace has whatever assistant the
developer already had signed in, which is usually Copilot against their own
account, and the demo argues against itself without any visible sign of it.

**Extension ids fail silently when wrong.** No extension, no error. Verify any id
at `open-vsx.org/extension/<publisher>/<name>` before adding it.

**Open VSX is reached over the internet by default.** Concede this before it is
pointed out: in a bank the answer is a private Open VSX registry, curated the same
way base images are. Same argument as act 3, one layer up.

## What to show in act 6

Seven minutes, shared with Ansible and the OAuth handshake. Do not turn this into
an RHOAI demo.

1. Trigger a completion in the IDE. Ten seconds, no narration needed.
2. `oc get inferenceservice -n devspaces-demo`. The model is a workload in this
   cluster, with a URL, a replica count and a GPU request.
3. `oc get networkpolicy`. Developer workspaces can reach it. Nothing else can.

**The line that lands:** on a laptop, "developers must only use the approved
assistant" is a policy you are trusting people to follow. Here it is an
environment variable in a devfile the platform team owns, pointed at an endpoint
only workspaces can reach, running on hardware you control. You have turned a
policy statement into a configuration fact.

Expect a follow-up about prompt logging, retention and whether completions are
auditable. That is a good outcome. The honest answer is that serving gives you a
place to put that control, and what gets logged is a decision their model serving
team makes, not something Dev Spaces decides for them.

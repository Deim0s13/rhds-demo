# Choosing the AI Backend

Act 6 needs a model. The workspace only ever needs an OpenAI-compatible base URL,
so the backend is a variable in `demo.env`, not a fork of the demo.

## Which one, when

| | `rhoai` | `ollama` |
|---|---|---|
| Environment needed | RHOAI with GPU | any OpenShift |
| Adds to bootstrap | ~10 to 20 min | ~5 min |
| Model | 7B coder on GPU, genuinely good | 1.5B on CPU, adequate |
| Best for | risk, security, EA, platform teams | app developers, tight timings, fallback |

**Default to `rhoai` when you have the environment and the room contains anyone
who owns risk or architecture.** The reason is not the model quality. It is that
an InferenceService served by a model serving team, consumed by a development
team, is the actual enterprise shape. It gives you a genuine separation of
concerns to point at in act 7: someone owns the model, someone owns serving,
someone owns the workspace stack, and they are three different teams with three
different approval paths.

**Fall back to `ollama` without embarrassment.** If the GPU environment is late,
if the InferenceService is still pulling weights twenty minutes before you start,
or if you are simply running to time, change one variable. The argument you are
making about where inference happens does not depend on which backend serves it.

## Running the RHOAI path

```bash
# demo.env
AI_BACKEND="rhoai"
AI_MODEL="qwen2.5-coder-7b-instruct"
AI_SERVICE_NAME="coder-model"
AI_MODEL_IMAGE="oci://quay.io/redhat-ai-services/modelcar-catalog:<tag>"
```

```bash
./scripts/up.sh
./scripts/render-devfiles.sh    # then commit and push, see below
./scripts/smoke.sh
```

### Confirm the ModelCar tag first

This is the single most likely thing to bite you. Catalogue tags move, and a bad
reference does not fail at `oc apply`, it fails minutes later when the
InferenceService tries to start.

```bash
oc image info quay.io/redhat-ai-services/modelcar-catalog:<tag>
```

If your environment has an internal mirror, point `AI_MODEL_IMAGE` at that. In a
bank this is the only acceptable answer anyway, and it is worth saying so live:
model weights are a supply chain artefact and belong under the same registry
controls as your base images. That connects neatly to the point you already made
in act 3 about scanned internal images.

### Devfiles have to be pushed

`render-devfiles.sh` writes the endpoint into the committed devfiles. Dev Spaces
fetches those from Git, so an unpushed change means the workspace silently uses
the old endpoint and the assistant times out in front of the customer.
`smoke.sh` checks for this drift; do not ignore that check.

## What to actually show in act 6

Six minutes, shared with the Ansible segment. Do not turn this into an RHOAI demo.

1. Trigger a completion in the IDE. Ten seconds, no narration needed.
2. `oc get inferenceservice -n <demo namespace>`. The model is a workload in this
   cluster, with a URL, a replica count and a GPU request.
3. `oc get networkpolicy`. Developer workspaces can reach it. Nothing else can.

**The line that lands:** on a laptop, "developers must only use the approved
assistant" is a policy you are trusting people to follow. Here it is an
environment variable in a devfile the platform team owns, pointed at an endpoint
that only workspaces can reach, running on hardware you control. You have turned
a policy statement into a configuration fact.

Expect the follow-up question about prompt logging, retention and whether
completions are auditable. That is a good outcome. The honest answer is that
serving gives you a place to put that control, and what gets logged is a decision
their model serving team makes, not something Dev Spaces decides for them.

## GPU capacity, said out loud

One GPU serves this demo. It does not serve four hundred developers. If they ask
about scaling, do not guess in the room. The shape of the answer is that
concurrency depends on model size, context length and request pattern, that
KServe will scale replicas against available GPUs, and that it is a sizing
exercise worth doing properly with their numbers. Offering to take that away is
a better outcome than an invented figure.

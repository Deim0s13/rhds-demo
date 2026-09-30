# What broke, and why

Every entry here cost between twenty minutes and two days to diagnose. They are
recorded because the error messages point somewhere other than the cause, and
because a colleague picking this up will otherwise repeat them.

`scripts/preflight.sh` checks most of these in thirty seconds. Run it first.

## Images and registries

**MinIO vanished mid-project.** MinIO deleted their Docker Hub repositories on
11 September 2026 and gated Quay.io on 24 September. Every tag now refuses
anonymous pulls, so pinning would not have helped. The last free community build
also carries an unpatched auth bypass (CVE-2026-40344, 8.8). Replaced with
SeaweedFS, which keeps the S3 API so only the endpoint and port changed.

This is the best act 3 material in the demo: a vendor removed their public
images from two registries inside a fortnight, and anyone pulling `minio:latest`
into a build had a broken pipeline that Friday. Some shipped the vulnerable
version. That is the argument for an internal registry and a curating platform
team, made by real events.

**`:latest` is a time bomb.** Four separate failures traced to unpinned
references. Where the cluster is authoritative, discover (vLLM runtime, chart
version, apps domain). Where it is not, pin by version or digest and record what
it was verified against. Preflight warns on any `:latest`.

**The vLLM runtime digest differs per environment.** `ba060ec1...` on one
cluster, `c056e616...` three weeks later. RHOAI ships runtime images matched to
its own version, so `discover_vllm_image` reads it from the cluster's
`vllm-cuda-runtime-template`. A pinned guess failed deep inside vLLM startup
_after_ an 18GB pull, with a tokeniser error that read like a model problem.

**ModelCar catalogue tags move.** `qwen2.5-coder-7b-instruct` did not exist;
`llama-3.2-3b-instruct` did. A bad reference fails in an init container minutes
later, not at apply time. `up.sh` validates it with `oc image info` first.

**`oc image info` refuses a multi-arch image.** Given a manifest list it exits
non-zero with "the image is a manifest list and contains multiple images", which
is indistinguishable from a missing tag if you are only checking the exit code.
Every caller now goes through `image_resolves` in `lib.sh`, which passes
`--filter-by-os=linux/amd64`. This was a false hard failure waiting to happen on
the one image check that stops a run.

**The prepull and the devfile must name the same image.** The Ansible dev tools
image is pinned in two places, and if they drift the prepull warms an image
nothing uses. Everything stays green and act 6 pulls several gigabytes cold in
front of the room. Preflight now compares the two strings directly, because no
other check can see the difference.

**Red Hat `:latest` tags stay.** `ubi9/openjdk-21:latest`, `rhel9/postgresql-16`
and `rhel9/redis-7` are deliberately unpinned. They are curated, continuously
patched streams and following them is the intended consumption pattern. Pinning
a UBI digest in a demo means demonstrating a stale base image, which argues
against the point act 3 is making. Preflight classifies these separately from a
genuinely unpinned third-party `:latest`, and that distinction is the whole
value of the check.

## OpenShift's restricted SCC

Every community image that assumes it owns its filesystem fails. OpenShift
assigns an arbitrary high UID with GID 0, so anything writable must be
group-writable.

- **Upstream Gitea** runs an s6 supervisor needing fixed paths. Dead end.
- **GitLab omnibus** runs a full init system and writes to `/etc/ssh`. Each path
  you mount over reveals another. Dead end; use the cloud-native chart.
- **`mc` (MinIO client)** wrote its config to `/.mc` because the arbitrary UID
  has no home directory. Fixed with `HOME=/tmp` and an `emptyDir`.
- **`fsGroup: 1000`** is rejected outright: "1000 is not an allowed group".
  OpenShift allocates a per-namespace range. Omit it and let admission assign.
- **Red Hat's images** (postgresql, redis) handle this natively, which is why
  they are used here rather than the community equivalents.

## Kubernetes behaviour that hides mistakes

**Jobs are immutable.** `oc apply` silently keeps the old spec, so a fixed Job
appears to change nothing. Three cycles were spent re-running a pod that had
already been fixed on disk. `up.sh` deletes before applying.

**Rolling updates deadlock on one GPU.** Default strategy is 25% max surge,
which rounds up to 1 with a single replica, so KServe starts a second predictor
that waits forever for a GPU the first one holds. Meanwhile the first serves
happily. Fixed with `deploymentStrategy: Recreate`.

**Operators cache API discovery at startup.** The GitLab operator looped on
"no matches for kind EnvoyProxy" for a full day _after_ the CRD was installed,
because the controller had started before it. `up.sh` installs the CRDs before
the Subscription and cycles the pod as insurance.

**CRD annotations have a 256KB limit.** `oc apply` writes the whole resource
into `last-applied-configuration`, and the EnvoyProxy CRD exceeds it:
"metadata.annotations: Too long". Use `--server-side`.

**Readiness probes copied between images.** `/usr/libexec/check-container` ships
with Red Hat's PostgreSQL image but not Redis. A perfectly healthy Redis failed
its rollout for twenty minutes on a probe that could never pass. TCP checks are
used where the health endpoint is not certain.

## YAML nesting passes every validator

`gatewayApi` nested inside `ingress` instead of beside it renders
`global.ingress.gatewayApi`, which the chart silently ignores. The document
parses, the CRD accepts it, the operator renders it, and the value is simply not
where you meant it. Four cycles. Preflight now asserts the structure, not just
that it parses.

## Empty substitutions are worse than missing ones

The original render guard only caught placeholders with _no_ rule. A rule whose
variable was empty substituted nothing and passed, producing `image: ` and an
`InvalidImageName` pod that sat in backoff for an hour. The guard now fails on
both cases.

## GitLab chart 10.x specifics

Nine distinct obstacles, in the order they appeared:

1. Chart version must match what the operator ships, and the list moves. It
   rejects others at admission and names the valid ones, which is the only way it
   exposes them. Now discovered by probing the webhook.
2. External PostgreSQL required (bundled subchart removed).
3. External Redis required.
4. Object storage connection required for artifacts, lfs, uploads, packages,
   even when unused. The secret key is `config`, not `connection`.
5. `global.gatewayApi.enabled: false` disables the Gateway API resources, and it
   is a sibling of `ingress`, not a child.
6. Envoy Gateway CRDs still needed despite that, via `--server-side`.
7. Operator discovery cache, as above.
8. The toolbox needs an s3cmd-format secret or it crashloops on a missing
   `/etc/gitlab/.s3cfg`, taking rails console and therefore seeding with it.
9. PostgreSQL 16 produces a "requires >= 17" banner and then proceeds normally.
   It is a warning, not a block. `rhel9/postgresql-17` was not in the catalogue.

## Dev Spaces specifics

**The editor is a creation-time choice, not a client you attach.** There is no
way to connect desktop VS Code or JetBrains to a workspace that was created with
the browser editor. Desktop VS Code needs the workspace created with the
`Visual Studio Code (desktop) (SSH)` editor, which runs sshd in the dev
container, plus `redhat.devspaces-remote-ssh` and a Remote-SSH implementation
locally. JetBrains needs a workspace created with a JetBrains editor, plus
Gateway and the Dev Spaces connector plugin, **and a paid JetBrains licence**:
the Gateway editors are all commercial IDEs, with no Community option.

Newer dashboards can change the editor on a **stopped** workspace. That is still
not a live attach, and it is not something to build an act around.

**Setting `AI_BASE_URL` does not give the workspace an assistant.** The env vars
sat in both devfiles for weeks with nothing reading them. No assistant extension
was installed, so the only one present was whatever the developer already had
signed in, which for most people is Copilot against their own GitHub account. The
demo appeared to work and was demonstrating the opposite of its own argument.

Fixed with two pieces that both have to be there: `.vscode/extensions.json`
listing `Continue.continue`, which Dev Spaces installs from Open VSX at startup,
and a `configure-ai` command on `postStart` that writes `~/.continue/config.yaml`
from the container environment. `smoke.sh` now checks for both, because this
failure is invisible unless you look at where a completion actually went.

Two things fall out of it. Extension ids fail silently when wrong, so verify each
at `open-vsx.org/extension/<publisher>/<name>`. And Open VSX is reached over the
internet by default, which contradicts the data-centre story: a bank runs a
private registry, curated like its base images.

**The desktop IDE is outside the assistant boundary, and that is not fixable.**
A local editor brings the developer's own extensions and their own network, so
Copilot works in a desktop IDE attached to a workspace and no devfile can prevent
it. Source and credentials still stay in the cluster. Assistant control does not.
This is a genuine tension between the act 4 benefit and the act 6 claim, and the
demo states it out loud rather than hoping nobody notices.

**A repeated repository URL reopens the existing workspace, and silently drops
your editor choice.** Paste a URL that already has a workspace, select a
different editor, and the dashboard opens the old workspace with its original
editor. Nothing warns you. It reads as the product ignoring the selector, and it
sent an hour down the drain before the cause was obvious.

Append `?new` to the URL to force a second workspace, or delete the existing one
first. Since act 4 is three workspaces from one repository, `?new` is not a
convenience here, it is what makes the act possible at all.

This is worth knowing for the demo design rather than just the mechanics. The
obvious choreography, one workspace with clients attaching and detaching while
state persists, is not possible. Three workspaces from one repository is both
achievable and a better argument, because the editors can be shown side by side.

**Only four SCM providers are supported**: azure, bitbucket, github, gitlab. An
unrecognised provider cannot resolve a devfile: Dev Spaces falls back to
offering a default one, which then fails to start, and the error reads as a
workspace problem. Three days went into Gitea before this surfaced as
`UnknownScmProviderException`. It is also a good act 7 point: self-hosting a
supported SCM properly is a platform project in itself.

**`subDir` is not valid** on a `projects` entry in schema 2.2.0. Devfiles here
carry no `projects` block at all: Dev Spaces clones the repository the workspace
came from, so declaring it is redundant and pinning a remote ties the file to one
SCM.

**Workspace containers need something that stays up.** The UBI OpenJDK
entrypoint expects to launch an application and exits when there is none, which
Kubernetes reads as a crash. `command: ["tail"]`, `args: ["-f","/dev/null"]`.

**The Route certificate must be trusted.** Dev Spaces cannot fetch a devfile
over the cluster's self-signed certificate until the CA is in its trust bundle,
and the failure looks like a GitLab problem. `trust-cluster-ca.sh`.

**First `gitlab-rails runner` on a fresh toolbox is a cold Rails boot** and can
take minutes. An unbounded `oc exec` hung `seed-gitlab.sh`, which hung `up.sh`,
producing no output at all. Now bounded at 240s with a clear fallback.

**Deleting a workspace does not discard its files.** Dev Spaces keeps `/projects`
on a per-user PVC that outlives the workspace, and Che skips cloning when the
project directory already exists. So a workspace recreated against an updated
repository can come up with the old clone: the old devfile, and no
`.vscode/extensions.json` if you just added one. Nothing looks wrong, the change
is simply not there.

`reset.sh` now deletes the per-user PVCs as well, after waiting for the workspace
pods to terminate, because the PVC delete hangs on its finalizer rather than
failing while a pod still mounts it.

**A re-seed fails precisely because the first seed worked.** GitLab protects the
default branch as soon as it exists, and `seed-gitlab.sh` force-pushes so the
repositories always match the working tree. First seed: fine. Every one after:
`You are not allowed to force push code to a protected branch`.

`seed-gitlab.sh` now unprotects `main` via
`DELETE /projects/:id/protected_branches/main` before pushing, swallowing the 404
that a first seed returns. Worth knowing that this class of bug only appears on
the second run, which is exactly the run nobody tests.

## Operational

**Rotating credentials means clearing state.** PostgreSQL and object storage set
credentials only when initialising an empty volume, so their PVCs must go too,
and Redis needs a pod restart. Half-rotating leaves authentication failures that
look like configuration errors. **Changing the credentials file path is itself a
rotation.**

**Credentials belong outside the repo.** They were written to `.demo-secrets` in
the working tree and committed twice, triggering two infosec notifications. A
gitignore entry is a control you must remember; keeping the file out of the tree
entirely is one that holds. They now live in `~/.config/rhds-demo/`, keyed by
cluster, and `lib.sh` refuses to run if the old file reappears.

**Run logs can contain tokens.** `seed-gitlab.sh` builds a remote URL containing
the API token, and git prints that URL on a push error. `*.log` is gitignored.

**Pin the cluster.** A stray kube context switch made every smoke check fail
against a cluster that was never set up, and the output read like a broken demo.
`up.sh` records what it provisioned; the other scripts assert against it.

**Images are garbage-collected overnight** on these environments. "It was warm
yesterday" is not good enough: run `smoke.sh` on the day.

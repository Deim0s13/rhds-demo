# Red Hat Dev Spaces Demo

A repeatable, code-only demo of Red Hat OpenShift Dev Spaces, built for a
40 minute customer session with Q&A. Stands up on a disposable OpenShift
environment and tears down without ceremony.

Audience: enterprise architects, platform teams, CISO and risk stakeholders in
regulated environments. The framing is deliberately banking-shaped.

## Quick start

```bash
cp demo.env.example demo.env      # edit GIT_ORG
oc login --token=... --server=...
./scripts/preflight.sh            # 30 seconds. Do not skip this.
./scripts/up.sh 2>&1 | tee up-$(date +%H%M).log
./scripts/smoke.sh                # run again 30 min before you present
```

Then read [`docs/RUNBOOK.md`](docs/RUNBOOK.md): act-by-act timings, the talk
track, the questions you will be asked, and what to do when something fails in
front of a customer.

**Run `preflight.sh` first, every time.** It checks in thirty seconds most of
what would otherwise fail forty minutes into a bring-up: a chart version the
operator no longer accepts, a registry that went private overnight, a moved
image tag, an empty variable rendering into a manifest, a fix that did not save.

## What the demo covers

| Act | Minutes | Shows |
|---|---|---|
| 1 | 4 | Framing: onboarding time and environment drift as real costs |
| 2 | 5 | Repository URL to running code, no local prerequisites |
| 3 | 6 | The devfile, and that it is ordinary Kubernetes underneath |
| 4 | 6 | Desktop VS Code and JetBrains against the same workspace |
| 5 | 8 | Authoring a devfile live, plus the approved-stack catalogue |
| 6 | 7 | Ansible authoring, per-user SCM OAuth, AI on an in-cluster model |
| 7 | 5 | Operating model: ownership, quota, cost, pilot selection |

## Layout

```
bootstrap/          Dev Spaces operator, CheCluster, namespace, image prepull
overlays/
  gitlab/           GitLab CE, plus the PostgreSQL, Redis and S3 it now requires
  rhoai/            vLLM ServingRuntime and InferenceService on GPU
  ollama/           CPU fallback for the AI assistant
samples/            source of truth; published into GitLab as standalone repos
  payments-service/   Prepared, has a devfile. Acts 2 to 4.
  ansible-automation/ Ansible authoring stack. Act 6.
  ledger-service/     No devfile on purpose. Act 5.
scripts/            preflight / up / seed-gitlab / smoke / reset / down / helpers
docs/               Runbook, live devfile build, AI backend, internal Git, lessons
```

## Design rules, if you extend this

- **Nothing cluster-specific in committed YAML.** Everything goes through
  `demo.env`, the generated credentials file, or runtime discovery, and
  `render()` refuses to apply a manifest with an unresolved *or empty*
  placeholder.
- **Discover where the cluster is authoritative, pin everywhere else.** The vLLM
  runtime image, the GitLab chart version and the apps domain are discovered
  because they differ per environment. Third-party images are pinned, because
  nothing on the cluster knows what you tested against.
- **Nothing sensitive in the working tree.** Credentials are generated into
  `~/.config/rhds-demo/`, keyed by cluster. This repo triggered two infosec
  notifications before that changed.
- **This repo is the asset; GitLab is the demo's SCM.** The samples live here as
  folders and are published into GitLab by `scripts/seed-gitlab.sh`. Nothing
  clones this repo at demo time.
- **Every new segment needs a runbook entry with a failure mode.** A demo asset
  without a recovery plan is a liability.
- **Read [`docs/LESSONS.md`](docs/LESSONS.md) before changing the
  infrastructure.** It records what broke and why, and most of it is
  non-obvious from the error messages.

## Reusing this

Fork it, change `GIT_ORG` in `demo.env`, run preflight then up. The runbook talk
track is opinionated on purpose; swap the banking framing for whatever your
account needs, but keep the three claims in act 1. They are what the rest of the
demo is evidence for.

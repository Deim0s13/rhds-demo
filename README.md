# Red Hat Dev Spaces Demo

A repeatable, code-only demo of Red Hat OpenShift Dev Spaces, built for a
40 minute customer session with Q&A. Designed to be stood up on a disposable
cluster in about 15 minutes and torn down without ceremony.

Audience: enterprise architects, platform teams, CISO and risk stakeholders in
regulated environments. The framing is deliberately banking-shaped.

## Quick start

```bash
cp demo.env.example demo.env      # edit GIT_ORG if you fork this
oc login --token=... --server=...
./scripts/up.sh                   # 10 to 15 minutes, safe to re-run
./scripts/smoke.sh                # run 30 min before you present
```

Then read [`docs/RUNBOOK.md`](docs/RUNBOOK.md). It has the act-by-act timings,
the talk track, the questions you will be asked, and what to do when something
does not work in front of a customer.

## What the demo covers

| Act | Minutes | Shows                                                                                                     |
| --- | ------- | --------------------------------------------------------------------------------------------------------- |
| 1   | 4       | Framing: onboarding time and environment drift as real costs                                              |
| 2   | 5       | Git URL to running code, no local prerequisites                                                           |
| 3   | 6       | The devfile, and that it is ordinary Kubernetes underneath                                                |
| 4   | 6       | Desktop VS Code and JetBrains against the same workspace                                                  |
| 5   | 8       | Authoring a devfile live, plus the curated registry                                                       |
| 6   | 6       | Ansible authoring stack, and an AI assistant on an in-cluster model (RHOAI/vLLM on GPU, or Ollama on CPU) |
| 7   | 5       | Operating model: ownership, quota, cost, pilot selection                                                  |

## Layout

```
bootstrap/    Operator, CheCluster, demo namespace, prepull DaemonSet
overlays/
  rhoai/              vLLM ServingRuntime + InferenceService on GPU
  ollama/             CPU fallback, always works
  gitea/              Internal Git, on by default
registry/     Curated devfile catalogue, the governance artefact
samples/            source of truth; published into Gitea as standalone repos
  payments-service/   Prepared, has a devfile. Acts 2 to 4.
  ansible-automation/ Ansible authoring stack. Act 6.
  ledger-service/     No devfile on purpose. Act 5.
scripts/      up / seed-gitea / smoke / reset / down, plus shared helpers
docs/         Runbook, live devfile build, AI backend and internal Git guides
```

## Design rules, if you extend this

- **No cluster-specific values in committed YAML.** Everything goes through
  `demo.env` and `scripts/lib.sh::render`. The environment rotates every five days.
- **`up.sh` must stay idempotent.** Re-running it on a fresh cluster is the
  normal case, not the exception.
- **This repo is the asset; Gitea is the demo's SCM.** The samples live here as
  folders and are published into Gitea as standalone repos by
  `scripts/seed-gitea.sh`. Nothing clones this repo at demo time.
- **Devfiles carry no `projects` block and no `subDir`.** Dev Spaces clones the
  repo the workspace came from. `subDir` is not valid in schema 2.2.0.
- **Every new segment needs a runbook entry with a failure mode.** A demo asset
  without a recovery plan is a liability, not an asset.

## Reusing this

Fork it, change `GIT_ORG` in `demo.env`, and the devfiles will point at your copy.
The runbook talk track is opinionated on purpose; swap the banking framing for
whatever your account needs, but keep the three claims in act 1. They are what
the rest of the demo is evidence for.

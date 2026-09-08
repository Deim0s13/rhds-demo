# Presenter Runbook

Target: 40 minutes of demo, 10 to 20 minutes of Q&A. If you are running late,
act 6 is the segment to cut.

## The argument you are making

Three claims, in this order. Every act should ladder back to one of them.

1. **Environments become a governed artefact.** A devfile in Git, reviewed like
   any other change, replaces a laptop setup guide that went stale months ago.
2. **The inner loop moves inside the platform boundary.** Same network zone,
   same policy, same base images as production. Source code and credentials
   never land on an endpoint. This is the CISO's reason to buy.
3. **Onboarding and drift become measurable.** Time to first commit is a number
   you can put on a slide. This is the CIO's reason to fund it.

## Your URLs

Fill these in after `up.sh` prints them. They change with every environment.

```
Dashboard  : https://devspaces.apps.<cluster>
Gitea      : https://gitea-devspaces-demo.apps.<cluster>
Samples    : https://gitea-devspaces-demo.apps.<cluster>/platform-engineering
```

Three repos, all in Gitea, nothing on the public internet:

| Repo                 | Used in                            |
| -------------------- | ---------------------------------- |
| `payments-service`   | acts 2 to 4                        |
| `ansible-automation` | act 6                              |
| `ledger-service`     | act 5, deliberately has no devfile |

## Before you walk in

- [ ] `scripts/up.sh` completed green, ideally a day ahead.
- [ ] `scripts/smoke.sh` green, run 30 minutes before you start.
- [ ] One workspace started once today, so images are hot on the node.
      This cluster has been observed to garbage-collect images overnight, so
      "it was warm yesterday" is not good enough.
- [ ] Desktop VS Code **and** JetBrains client both paired to the cluster once
      already. Do not do first-time OAuth on stage.
- [ ] Gitea UI open in a tab, logged in. You will show it in act 5.
- [ ] Browser zoom set so the back row can read an IDE.
- [ ] Notifications off.
- [ ] `scripts/reset.sh` run since the last session.

---

## Act 1, framing (4 min, one slide or none)

Ask the room: how long from a new developer's first day to their first merged
commit? Let them answer. In most banks the honest number is two to six weeks,
and most of it is environment setup, access requests and version mismatches.

Then name the second cost, which they usually have not counted: every one of
those environments is different, and the difference only shows up in an incident.

Do not show a product slide. Go straight to the browser.

## Act 2, the first sixty seconds (5 min)

Dashboard, Create Workspace, paste the `payments-service` Gitea URL. Say nothing
about devfiles yet. Narrate only what the developer experiences.

- Workspace starts, project already cloned.
- Run the `run` command, endpoint appears, open it, hit `/api/payments`.
- Edit `PaymentController`, restart, show the change.

**Land it:** no JDK install, no Maven config, no proxy settings, no access
request. And note in passing that the repository is internal. Nothing in what
they just watched touched the public internet.

**If it is slow:** you did not run `smoke.sh`. Talk over it by walking the
CheCluster idle timeout settings while the pod pulls.

## Act 3, peel the layer back (7 min)

Open `devfile.yaml` in the running workspace and walk it top to bottom.

- `components.container.image`: **the governance hinge**. In their bank this is
  an internally built, scanned image carrying the corporate CA bundle. Platform
  team owns it, so a base image CVE is one rebuild, not 400 laptops.
- `endpoints`: how the app got a URL, and that `exposure` is a real control.
- `commands`: build, run, test, debug declared, not tribal knowledge.
- No `projects` block: Dev Spaces clones the repo the workspace came from, so
  this devfile works unchanged against Bitbucket or GitHub Enterprise.

Then drop to a terminal, `oc get pods`, show it is just Kubernetes. Show quota.

**The image story, and use it, because it is real.** Gitea in this demo runs on
an image you had to build yourself. The upstream community image will not start
under OpenShift's restricted SCC: it runs a supervisor that needs to write to
paths it owns, and OpenShift assigns an arbitrary UID with GID 0. The rootless
variant gets further and still fails on `/var/lib/gitea` and `/etc/gitea`.

Three lines fixed it (`images/gitea/Containerfile`): make those paths
group-writable, set a numeric user. That is the standard OpenShift image
convention, and doing it is exactly the work a platform team does before
publishing an approved image.

The point to land: this is not an inconvenience, it is the security policy
working. Every image in your estate has to pass it. Somebody has to own doing
that. And it is precisely why the `image:` line in a devfile should point at
something your platform team has already put through this, not at whatever the
developer found on Docker Hub.

**Be honest about the trade-off, out loud.** You have moved cost from the laptop
to the cluster. That needs node capacity planning and an idle timeout policy.
Point at `secondsOfInactivityBeforeIdling` and say who should own that number.
Saying this unprompted buys enormous credibility with the platform team, and
they are usually the ones who can kill the deal.

## Act 4, local IDE and the handoff (6 min)

This act exists to kill one objection: _"our senior developers will never give up
IntelliJ."_

1. From the workspace, connect **desktop VS Code**. Same container, same running
   process, local keybindings and extensions.
2. Close it. Connect **JetBrains** to the same workspace.
3. Back to the browser tab. State is still there.

**Land it:** the environment is the governed thing. The editor is a personal
preference, and the platform team no longer has to have an opinion about it.

**Failure mode:** if a client will not connect, do not debug live. Say "I have
this working in the browser, let me come back to the desktop client at the end"
and move on. You lose 90 seconds; debugging on stage loses the room.

## Act 5, author a devfile live (8 min)

Create a workspace from `ledger-service`, which deliberately has no devfile.
Follow `docs/DEVFILE-LIVE-BUILD.md`, which has the sequence and the finished
file in case you need to paste rather than type.

Build it in four passes: component, command, endpoint, then start it.

Then open the Gitea UI beside it and make the governance point: this is a
catalogue the platform team publishes. A new approved stack is a pull request
reviewed by accountable people, not a ticket and not a wiki page.

**This is the act to invest rehearsal time in.** It proves the whole thing is
code, and it is the one most likely to go sideways if you improvise.

## Act 6, Ansible, credentials and in-cluster AI (7 min)

Three things, all short. Cut the AI segment first if you are behind.

**Ansible workspace.** Start it from `ansible-automation`. Show `ansible-lint`
running against `playbooks/site.yml` and module documentation inline. The point:
Dev Spaces is not only for application developers. Automation and infrastructure
content deserves the same governed authoring loop and the same review path. For
most banks this is the segment that surprises people.

**Platform-injected Git credentials.** In a workspace terminal, make a small
change and `git push` to Gitea. Nothing was typed. Then `oc get secret -n <user
namespace>` to show where it came from. The line: the platform provisioned this,
the developer never saw it, and revoking it is a secret rotation rather than a
fleet-wide laptop problem.

Then raise the OAuth point yourself, before anyone asks. What you showed is a
service-account token; against their Bitbucket or GitHub Enterprise it would be
OAuth against the identity provider OpenShift already uses, scoped per developer,
revoked when they leave. The real thing is stronger than the demo. Full talk
track in `docs/INTERNAL-GIT.md`.

**In-cluster AI assistant.** Trigger a completion, then
`oc get inferenceservice -n devspaces-demo` and the NetworkPolicy: a GPU-backed
model served by the platform, reachable from developer workspaces and nothing
else.

The line: on a laptop, "developers must only use the approved assistant" is a
policy you are trusting people to follow. Here it is an environment variable in
a devfile the platform team owns, pointed at an endpoint only workspaces can
reach. You have turned a policy statement into a configuration fact.

## Act 7, operating model close (5 min)

No demo, just conversation. Put these to the room rather than answering them.

- Who owns the devfile catalogue, and what is the SLA on approving a new stack?
- Who owns the base images, and what happens when a CVE lands?
- Who owns model serving, and is that the same team? (It is not.)
- How is quota set, and who gets the bill?
- Which teams go first, and what makes them a good pilot?

**Close:** Dev Spaces is a platform product. It needs an owner, a backlog and a
funding line. Treated as a tool you install, it will drift and people will go
back to their laptops. Treated as a product, it is the cheapest environment
governance you will ever buy.

---

## Q&A, the questions you will actually get

**"What happens when the cluster is down?"** Developers stop. Same as when Git
or your artefact repository is down. It belongs in the same availability tier,
and it is worth sizing that early rather than in an incident review.

**"Does this work offline or on a plane?"** No. If you have a meaningful
population who genuinely need offline development, Dev Spaces is not their tool
and you should say so. Most bank developers are on a VPN anyway.

**"What about licensing and node cost?"** Cost moves from laptop refresh cycles
to cluster capacity. Idle timeout and per-user workspace limits are the levers.
Do not guess numbers in the room; take it away.

**"How many developers can one GPU serve?"** Not a number, a sizing exercise.
The constraint is the KV cache, which scales with context length times
concurrent requests, not the model weights. In this demo the model advertises
131k context and had to be capped at 8k to fit on one card. Offer to size it
properly with their numbers.

**"Can we use our own images?"** Yes, and you should. See act 3.

**"How does this relate to Codespaces or Gitpod?"** It runs on the OpenShift they
already own, in their network zone, under their existing controls, with no code
leaving the boundary.

**"Which teams should go first?"** Teams with high onboarding churn, a painful
setup, or contractors and third parties who should never have source on their
machines. That last one is often the strongest pilot and usually has a budget.

## Failure modes and recovery

| Symptom                                | Cause                                             | Do this                                                                                            |
| -------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Workspace slow to start                | Cold image pull                                   | Talk over it, walk the CheCluster spec. Run `smoke.sh` next time.                                  |
| Desktop IDE will not attach            | Token expired or pairing lost                     | Skip it, promise to return at the end. Never debug live.                                           |
| Clone from Gitea fails                 | Credentials not mounted                           | `scripts/gitea-credentials.sh`, then restart the workspace.                                        |
| Ansible workspace OOM                  | `memoryLimit` too low for molecule                | Already at 8Gi; raise before the session if needed.                                                |
| AI completion never returns            | Model restarting, or devfile has a stale endpoint | `oc get inferenceservice -n devspaces-demo`. Re-run `scripts/seed-gitea.sh` if the endpoint moved. |
| Predictor Pending beside a Running one | Rolling update deadlocked on one GPU              | Should not recur (`deploymentStrategy: Recreate`). If it does, delete the stale ReplicaSet.        |
| `InvalidImageName` on the predictor    | A placeholder was not substituted                 | `render` now refuses to apply these. Check `AI_RUNTIME_IMAGE` and the sed rules in `lib.sh`.       |

## Cluster rotation

The environment lasts five days. On a fresh one:

```bash
cp demo.env.example demo.env   # first time only, then keep it
oc login --token=... --server=...
./scripts/up.sh                # 15 to 40 min: operator, Gitea build, model pull
./scripts/smoke.sh
```

Everything is discovered or configured, so nothing should need editing between
environments. The one value worth re-checking is `AI_MODEL_IMAGE`, since
ModelCar catalogue tags move. `up.sh` validates it before applying anything.

Budget more time than you think for the first run on a new cluster. The vLLM
runtime image is 18GB and the ModelCar is 6.4GB; observed first-pull times were
around 12 minutes each.

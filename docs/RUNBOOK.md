# Presenter Runbook

Target: 40 minutes of demo, 10 to 20 minutes of Q&A. Timings below are the ones
that survived rehearsal. If you are running late, act 6 is the segment to cut.

## The argument you are making

Three claims, in this order. Every act should ladder back to one of them.

1. **Environments become a governed artefact.** A devfile in Git, reviewed like
   any other change, replaces a laptop setup guide that went stale months ago.
2. **The inner loop moves inside the platform boundary.** Same network zone,
   same policy, same base images as production. Source code and credentials
   never land on an endpoint. This is the CISO's reason to buy.
3. **Onboarding and drift become measurable.** Time to first commit is a number
   you can put on a slide. This is the CIO's reason to fund it.

## Before you walk in

- [ ] Backend chosen in `demo.env` (`AI_BACKEND`), see `docs/AI-BACKEND.md`.
- [ ] Decided whether Gitea is on (`DEPLOY_GITEA`), see `docs/INTERNAL-GIT.md`.
      If on: credentials injected and a workspace restarted since.
- [ ] On the RHOAI path: ModelCar tag confirmed with `oc image info`.
- [ ] `scripts/up.sh` completed, at least a day ahead if you can.
- [ ] `scripts/render-devfiles.sh` run, **and the result committed and pushed**.
- [ ] `scripts/smoke.sh` green, run 30 minutes before you start.
- [ ] One workspace already started once today, so images are hot.
- [ ] Desktop VS Code **and** JetBrains client both paired to the cluster once
      already. Do not do first-time OAuth on stage.
- [ ] Browser logged in, dashboard open in a tab, zoom set so the back row can read it.
- [ ] Phone and notifications off. You will be screen sharing an IDE.
- [ ] `scripts/reset.sh` run since the last session.

---

## Act 1, framing (4 min, one slide or none)

Ask the room: how long from a new developer's first day to their first merged
commit? Let them answer. In most banks the honest number is two to six weeks,
and most of it is environment setup, access requests and version mismatches.

Then name the second cost, which is the one they usually have not counted: every
one of those environments is different, and the difference only shows up in an
incident.

Do not show a product slide. Go straight to the browser.

## Act 2, the first sixty seconds (5 min)

From the dashboard, create a workspace from the Spring Boot sample Git URL.
Say nothing about devfiles yet. Narrate only what the developer experiences.

- Workspace starts, project is already cloned.
- Run the `run` command, endpoint appears, open it, hit `/api/payments`.
- Make a small edit to `PaymentController`, restart, show the change.

**Land it:** no JDK install, no Maven config, no proxy settings, no access request.
Every developer on this team gets the byte-identical environment.

**If it is slow:** you did not run `smoke.sh`. Talk over it by walking the
CheCluster idle timeout settings while the pod pulls.

## Act 3, peel the layer back (6 min)

Open `devfile.yaml` in the running workspace and walk it top to bottom.

- `projects`: why the clone was automatic.
- `components.container.image`: **the governance hinge**. In their bank this is
  an internally built, scanned image carrying the corporate CA bundle. The
  platform team owns it, so a base image CVE is one rebuild, not 400 laptops.
- `endpoints`: how the app got a URL, and that `exposure` is a real control.
- `commands`: build, run, test, debug are declared, not tribal knowledge.

Then drop to a terminal and `oc get pods` in the workspace namespace. Show it is
just Kubernetes. Show the quota.

**Be honest about the trade-off, out loud.** You have moved cost from the laptop
to the cluster. That needs node capacity planning and an idle timeout policy.
Point at `secondsOfInactivityBeforeIdling` in the CheCluster and say who should
own that number. Saying this unprompted buys you enormous credibility with the
platform team in the room, and they are usually the ones who can kill the deal.

## Act 4, local IDE and the handoff (6 min)

This act exists to kill one specific objection: *"our senior developers will
never give up IntelliJ."*

1. From the workspace, connect **desktop VS Code**. Same container, same running
   process, local keybindings and extensions.
2. Close it. Connect **JetBrains** to the same workspace.
3. Go back to the browser tab. The state is still there.

**Land it:** the environment is the governed thing. The editor is a personal
preference, and the platform team no longer has to have an opinion about it.

**Failure mode:** if a client will not connect, do not debug live. Say "I have
this working in the browser, let me come back to the desktop client at the end"
and move on. You lose 90 seconds. Debugging on stage loses the room.

## Act 5, author a devfile live (8 min)

Open `samples/bare-app`, which deliberately has no devfile. Follow
`docs/DEVFILE-LIVE-BUILD.md`, which has the exact sequence and the finished file
in case you need to paste rather than type.

Build it up in four passes: component, then command, then endpoint, then project.
Start the workspace. It works.

Then open `registry/index.json` and make the governance point: this is a
catalogue the platform team publishes. A new approved stack is a pull request
reviewed by accountable people, not a ticket and not a wiki page.

**This is the act to invest rehearsal time in.** It is the one that proves the
whole thing is code, and it is the one most likely to go sideways if you improvise.

## Act 6, the Ansible stack and in-cluster AI (6 min)

Two things here, both chosen because they broaden who cares.

**Ansible workspace.** Start it from the registry. Show `ansible-lint` running
against `playbooks/site.yml`, the extension giving module documentation inline,
and `molecule` available. The point: Dev Spaces is not only for application
developers. Your automation and infrastructure content deserves the same
governed authoring loop, the same linting, and the same review path. For most
banks this is the segment that surprises people.

**Platform-injected Git credentials** (only if `DEPLOY_GITEA=true`). In a
workspace terminal, make a small change and `git push`. Nothing was typed. Then
`oc get secret -n <user namespace>` to show where it came from. Ninety seconds.
The line: the platform provisioned this, the developer never saw it, and
revoking it is a secret rotation rather than a fleet-wide laptop problem.

Then raise the OAuth point yourself, before anyone asks. What you showed is a
service-account token; against their Bitbucket or GitHub Enterprise it would be
OAuth against the identity provider OpenShift already uses, scoped per developer,
revoked when they leave. The real thing is stronger than the demo. Full talk
track and the follow-up questions in `docs/INTERNAL-GIT.md`.

**In-cluster AI assistant.** Show a completion in the IDE, then show where it
came from. On the RHOAI path that is `oc get inferenceservice -n <demo namespace>`
plus the NetworkPolicy: a GPU-backed model served by the platform, reachable from
developer workspaces and nothing else. On the Ollama path it is a pod in the same
namespace. Either way, nothing leaves the cluster boundary.

See `docs/AI-BACKEND.md` for which backend to run and why.

**Land it, carefully.** The interesting claim is not that AI writes code. It is
that the workspace is where you can *enforce* which assistant a developer uses
and where inference happens. On a laptop you are trusting policy. Here it is
configuration. Expect a risk or compliance person to follow up on this; that is
a good outcome, not an interruption.

## Act 7, operating model close (5 min)

No demo, just conversation. Put these questions to the room rather than
answering them yourself.

- Who owns the devfile registry, and what is the SLA on approving a new stack?
- Who owns the base images, and what happens when a CVE lands?
- How is quota set, and who gets the bill?
- What is the idle timeout, and who is allowed to change it?
- Which teams go first, and what makes them a good pilot?

**Close:** Dev Spaces is a platform product. It needs an owner, a backlog and a
funding line. Treated as a tool you install, it will drift and people will go
back to their laptops. Treated as a product, it is the cheapest environment
governance you will ever buy.

---

## Q&A, the questions you will actually get

**"What happens when the cluster is down?"** Honest answer: developers stop.
Same as when your Git server or artefact repository is down. It belongs in the
same availability tier, and it is worth sizing that conversation early rather
than discovering it in an incident review.

**"Does this work offline or on a plane?"** No. If you have a meaningful
population who genuinely need offline development, Dev Spaces is not their tool
and you should say so. Most bank developers are on a VPN to a data centre anyway.

**"What about our licensing and node cost?"** Cost moves from laptop refresh
cycles to cluster capacity. Idle timeout and per-user workspace limits are the
levers. Do not guess numbers in the room, take it away.

**"Can we use our own images?"** Yes, and you should. That is the point.

**"Is the Git integration really that clean, or is that a demo shortcut?"**
Be straight: the credential injection you saw is the weaker of the two patterns.
Their SCM gets OAuth, per-user identity, revocation through their IdP. You showed
the lesser version because of the demo environment, not the product.

**"How does this relate to Codespaces or Gitpod?"** The differentiator that
matters in a bank is that this runs on the OpenShift you already own, in your
network zone, under your existing controls, with no code leaving the boundary.

**"Which teams should go first?"** Teams with high onboarding churn, a painful
setup, or contractors and third parties who should never have source on their
machines. That last one is often the strongest pilot case and it usually has a
budget already.

## Failure modes and recovery

| Symptom | Cause | Do this |
|---|---|---|
| Workspace takes minutes to start | Cold image pull | Talk over it, walk the CheCluster spec. Run `smoke.sh` next time. |
| Desktop IDE will not attach | Token expired or pairing lost | Skip it, promise to return at the end. Do not debug live. |
| Ansible workspace out of memory | `memoryLimit` too low for molecule | Bump to 8Gi in the devfile before the session. |
| AI completion never returns | Model still loading, or devfile points at a stale endpoint | `oc get inferenceservice -n <ns>`. If it is Ready, you probably forgot to push the rendered devfile. Talk about placement rather than showing it. |
| InferenceService stuck Pending | No allocatable GPU, or bad ModelCar reference | `oc describe pod -l component=predictor -n <ns>`. Set `AI_BACKEND=ollama` and re-run `up.sh`, roughly 5 minutes. |
| Clone fails from Gitea | Credentials not mounted | Run `scripts/gitea-credentials.sh`, restart the workspace. |
| Dashboard 503 | CheCluster still reconciling | `oc get checluster devspaces -n <ns> -o jsonpath='{.status.chePhase}'` |

## Cluster rotation

The environment lasts five days. On a fresh one:

```bash
cp demo.env.example demo.env   # first time only, then keep it
oc login --token=... --server=...
./scripts/up.sh                # 10 to 15 min, longer on the RHOAI path
./scripts/render-devfiles.sh   # then git commit && git push
./scripts/smoke.sh             # then start one workspace manually
```

Nothing in the repo hardcodes a cluster. If you find something that does, that
is a bug, fix it in `demo.env` and `scripts/lib.sh::render`.

# Presenter Runbook

Target: 40 minutes of demo, 10 to 20 minutes of Q&A. If you are running late,
act 6 is the segment to cut.

**This file is the map: what each act argues, and why it is in this order.**
`docs/PRESENTER-SCRIPT.md` is the turn-by-turn, what you click and what you say
while it happens. Read this one once, rehearse from that one.

Timings marked `[measure]` are estimates until you have rehearsed on a real
cluster. `scripts/rehearse.sh` measures them: it watches for the workspace you
create in the dashboard and times it through to Running, so you are timing the
real path rather than a synthetic one. `--table` prints the rest to fill in with
a phone. Estimates are what make you overrun.

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

`scripts/smoke.sh` prints these. They change with every environment.

```
Dashboard : https://devspaces.apps.<cluster>
GitLab    : https://gitlab.apps.<cluster>
Samples   : https://gitlab.apps.<cluster>/platform-engineering
Root pw   : oc get secret gitlab-gitlab-initial-root-password -n gitlab-system \
              -o jsonpath='{.data.password}' | base64 -d
```

| Repo                 | Used in                            |
| -------------------- | ---------------------------------- |
| `payments-service`   | acts 2 to 4                        |
| `ansible-automation` | act 6                              |
| `ledger-service`     | act 5, deliberately has no devfile |

## Before you walk in

- [ ] `scripts/preflight.sh` green.
- [ ] `scripts/up.sh` completed, ideally a day ahead.
- [ ] `scripts/smoke.sh` green, run 30 minutes before you start.
- [ ] **OAuth handshake already done.** Start a workspace from
      `payments-service` once and complete the GitLab authorisation. It happens
      once per user and you do not want to be typing a root password on stage.
      If you want to _show_ the handshake, see act 6.
- [ ] One workspace started today, so images are hot. These environments
      garbage-collect images overnight, so yesterday does not count.
- [ ] **Three workspaces created, one per editor**, and desktop VS Code and
      JetBrains Gateway both connected to theirs. The editor cannot be changed
      on a running workspace, so act 4 has no live starts in it.
- [ ] JetBrains licence confirmed, or act 4 planned as VS Code only.
- [ ] GitLab UI open in a tab, logged in as root.
- [ ] Browser zoom set so the back row can read an IDE.
- [ ] Notifications off.
- [ ] `scripts/reset.sh` run since the last rehearsal, so `ledger-service` is
      devfile-free again.
- [ ] Timings measured at least once on this cluster, `scripts/rehearse.sh`.
      Knowing you have 90 seconds of talking to do in act 2 is the difference
      between narrating and waffling.
- [ ] The paste-ready commands from `docs/PRESENTER-SCRIPT.md` in a scratch
      file, with `<username>` already substituted.

---

## Act 1, framing (4 min, one slide or none)

Ask the room: how long from a new developer's first day to their first merged
commit? Let them answer. In most banks the honest number is two to six weeks,
and most of it is environment setup, access requests and version mismatches.

Then name the second cost, which they usually have not counted: every one of
those environments is different, and the difference only shows up in an
incident.

Do not show a product slide. Go straight to the browser.

## Act 2, the first sixty seconds (5 min) `[measure cold start]`

Dashboard, Create Workspace, paste the `payments-service` GitLab URL. Say
nothing about devfiles yet. Narrate only what the developer experiences.

- Workspace starts, project already cloned.
- Run the `run` command, endpoint appears, open it, hit `/api/payments`.
- Edit `PaymentController`, restart, show the change.

**Land it:** no JDK install, no Maven config, no proxy settings, no access
request. And note in passing that the repository is internal, on GitLab in this
cluster. Nothing they just watched touched the public internet.

**If it is slow:** you did not run `smoke.sh`. Talk over it by walking the
CheCluster idle timeout settings while the pod pulls.

## Act 3, peel the layer back (6 min)

Open `devfile.yaml` in the running workspace and walk it top to bottom.

- `components.container.image`: **the governance hinge**. In their bank this is
  an internally built, scanned image carrying the corporate CA bundle. The
  platform team owns it, so a base image CVE is one rebuild, not 400 laptops.
- `endpoints`: how the app got a URL, and that `exposure` is a real control.
- `commands`: build, run, test, debug declared, not tribal knowledge.
- No `projects` block: Dev Spaces clones the repo the workspace came from, so
  this devfile works unchanged against their Bitbucket or GitHub Enterprise.

Then drop to a terminal, `oc get pods`, show it is just Kubernetes. Show quota.

**Be honest about the trade-off, out loud.** You have moved cost from the laptop
to the cluster. That needs node capacity planning and an idle timeout policy.
Point at `secondsOfInactivityBeforeIdling` and say who should own that number.
Saying this unprompted buys enormous credibility with the platform team, and
they are usually the ones who can kill the deal.

**The supply chain story, and use it, because it is real and recent.** MinIO
deleted their public container images from Docker Hub on 11 September 2026 and
gated Quay.io on the 24th. This demo broke because of it. Every tag now refuses
anonymous pulls, so pinning a version would not have saved you. And the last
free community build carries an unpatched authentication bypass rated 8.8.

Anyone pulling `minio:latest` from a public registry straight into a build had a
broken pipeline that Friday, and some of them shipped the vulnerable version.
That is the argument for an internal registry, pinned digests, and a platform
team that curates images, made by events rather than a hypothetical. It lands
harder than any feature.

Cut this if act 3 is running long. It is a bonus, not the point.

## Act 4, local IDE and the handoff (6 min) `[measure attach time]`

This act exists to kill one objection: _"our senior developers will never give
up IntelliJ."_

**The editor is a creation-time choice.** You cannot attach a desktop IDE to a
workspace created with the browser editor, so this act is three workspaces from
the same repository, one per editor, all created and connected before you start.
`docs/PRESENTER-SCRIPT.md` has the editor names and the local prerequisites.

1. Browser workspace, your reference point from acts 2 and 3.
2. Desktop VS Code, already connected. `hostname` and `oc whoami` in its
   terminal prove the shell is in the cluster and the source is not local.
3. JetBrains, already connected to its own workspace.

**Land it:** the environment is the governed thing. The editor is a personal
preference, and the platform team no longer has to have an opinion about it.

**Say the shape out loud.** Someone will notice these are three workspaces. Own
it first: the editor is part of the environment definition, a developer chooses
once, and three pods while you demonstrate three editors is a capacity point
that ties back to quota.

**JetBrains Gateway requires a paid licence** (IntelliJ IDEA Ultimate, WebStorm,
PyCharm Professional, RubyMine, CLion). No licence means act 4 is VS Code only
and JetBrains is covered verbally. Establish this weeks out.

**Failure mode:** if a client has dropped its connection, do not reconnect live.
Say "I have this working in the browser, let me come back to the desktop client
at the end" and move on. You lose 90 seconds; debugging on stage loses the room.

## Act 5, author a devfile live (8 min) `[measure]`

Create a workspace from `ledger-service`, which deliberately has no devfile.
Follow `docs/DEVFILE-LIVE-BUILD.md`, which has the sequence and the finished
file in case you need to paste rather than type.

Build it in four passes: component, command, endpoint, then commit.

Then open the GitLab UI beside it and make the governance point: these are
approved stacks published by a platform team. A new one is a merge request
reviewed by accountable people, not a ticket and not a wiki page.

**This is the act to invest rehearsal time in.** It proves the whole thing is
code, and it is the one most likely to go sideways if you improvise.

**Reset afterwards.** Once you commit a devfile into `ledger-service` that repo
is no longer devfile-free. `scripts/reset.sh` force-pushes it back.

## Act 6, Ansible, identity and in-cluster AI (7 min)

Three things, all short. Cut the AI segment first if you are behind.

**Ansible workspace.** Start it from `ansible-automation`. Show `ansible-lint`
running against `playbooks/site.yml` and module documentation inline. The point:
Dev Spaces is not only for application developers. Automation and infrastructure
content deserves the same governed authoring loop and the same review path. For
most banks this is the segment that surprises people.

**Per-user OAuth against the SCM.** This is a live moment rather than a talk
track, and it is the strongest security content in the demo.

To show the handshake you need to be a first-time user, so use a second browser
profile or an incognito window. Create a workspace from a GitLab URL: Dev Spaces
redirects to GitLab, the developer authenticates **as themselves**, authorises
the Dev Spaces application, and the workspace clones.

What to say while it happens:

> Notice what did not occur. I was not handed a credential to paste. Dev Spaces
> never saw my password. What it holds is an OAuth token scoped to me, stored in
> the cluster, not on a laptop. My commits attribute to me. And when I leave,
> that access dies with my identity in the directory, not whenever someone
> remembers to go looking for a shared service account.

Then show where it lives: `oc get secrets -n <username>-devspaces`.

Contrast with the status quo out loud: a cloned repository on a departing
contractor's laptop is a real problem most organisations have no clean answer
to. This is that answer.

**In-cluster AI assistant.** Trigger a completion, then
`oc get inferenceservice -n devspaces-demo` and the NetworkPolicy: a GPU-backed
model served by the platform, reachable from developer workspaces and nothing
else.

The line: on a laptop, "developers must only use the approved assistant" is a
policy you are trusting people to follow. Here it is an environment variable in
a devfile the platform team owns, pointed at an endpoint only workspaces can
reach. You have turned a policy statement into a configuration fact.

**Do this in the browser workspace, and name the boundary yourself.** That claim
holds in the browser IDE, where the devfile owns the toolchain. It does not hold
in the desktop IDE: the developer's own extensions come with their editor, so
Copilot signed into a personal account works and the devfile cannot stop it.
Source and credentials still stay in the cluster, which is most of the value, but
assistant control is not part of it. Saying so unprompted is worth more than the
completion itself; discovered later, it makes everything else you claimed look
shaky. `docs/PRESENTER-SCRIPT.md` has the wording.

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

**"Is that Git integration real, or a demo shortcut?"** Real. It is the same
OAuth mechanism Dev Spaces uses for Bitbucket Data Center, GitHub Enterprise,
GitLab and Azure DevOps. Those four are the supported providers, which is worth
knowing: anything else needs a token in a secret, which works but gives you a
shared identity rather than a per-user one.

**"Can we use our own images?"** Yes, and you should. See act 3.

**"How does this relate to Codespaces or Gitpod?"** It runs on the OpenShift
they already own, in their network zone, under their existing controls, with no
code leaving the boundary.

**"Which teams should go first?"** Teams with high onboarding churn, a painful
setup, or contractors and third parties who should never have source on their
machines. That last one is often the strongest pilot and usually has a budget.

## Failure modes and recovery

| Symptom                              | Cause                                                 | Do this                                                                                                     |
| ------------------------------------ | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Workspace slow to start              | Cold image pull                                       | Talk over it, walk the CheCluster spec. Run `smoke.sh` next time.                                           |
| "Failed to fetch devfile"            | SCM wiring missing                                    | `smoke.sh` catches this. Check `gitServices.gitlab` on the CheCluster and the `gitlab-oauth-config` secret. |
| GitLab asks for credentials mid-demo | First-time OAuth for that user                        | Expected once per user. Do it before you present, or use it deliberately in act 6.                          |
| Desktop IDE will not attach          | Token expired or pairing lost                         | Skip it, promise to return at the end. Never debug live.                                                    |
| AI completion never returns          | Model restarting, or the devfile has a stale endpoint | `oc get inferenceservice -n devspaces-demo`. Re-run `seed-gitlab.sh` if the endpoint moved.                 |
| Ansible workspace OOM                | `memoryLimit` too low for molecule                    | Already at 8Gi; raise before the session if needed.                                                         |
| Workspace container crashloops       | Image entrypoint exits with nothing to run            | The devfile needs `command: ["tail"]`, `args: ["-f","/dev/null"]`.                                          |

## Cluster rotation

These environments last about five days.

```bash
cp demo.env.example demo.env   # first time only, then keep it
oc login --token=... --server=...
./scripts/preflight.sh
./scripts/up.sh 2>&1 | tee up-$(date +%H%M).log
./scripts/smoke.sh
# then create a workspace once and complete the OAuth handshake
```

Everything cluster-specific is discovered or generated, so nothing should need
editing between environments. Preflight tells you within thirty seconds if that
turns out not to be true.

Budget generously for a first run. The vLLM runtime image is around 18GB, the
ModelCar 6.4GB, and GitLab's migrations take roughly 12 minutes after its own
images pull.

`docs/LESSONS.md` records everything that has broken and why. Read it before
changing the infrastructure; most of it is non-obvious from the error messages.

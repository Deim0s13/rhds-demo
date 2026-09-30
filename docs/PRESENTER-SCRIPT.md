# Presenter Script

`RUNBOOK.md` is the map: what each act argues and why it is in that order. This
is the turn-by-turn: what you click, what you type, what you say while it
happens. Act 5 has its own file, `DEVFILE-LIVE-BUILD.md`, because typing a file
live needs a different kind of instruction.

Read the runbook once. Rehearse from this.

## Before anything

Run `scripts/smoke.sh` and take the three workspace URLs it prints. Every step
below says "the payments URL" rather than a literal address, because it changes
with every environment and a stale URL in a script is a trap.

**Act 4 needs three workspaces created in advance, one per editor.** The editor
is a creation-time choice and cannot be swapped on a running workspace, so this
cannot be done on stage. See act 4 for the editor names and what you install
locally, and settle the JetBrains licence question early.

Two windows, arranged before the room fills:

- **Browser**, full screen, three tabs: Dev Spaces dashboard, GitLab group page,
  and one blank tab for a fresh incognito window later.
- **Terminal**, large font, in the repo directory, already logged in.
- **Desktop VS Code and JetBrains Gateway** both already connected to their own
  workspaces, minimised.

Zoom so the back row can read a stack trace. Test that from the back of the room
if you can get in early. Everything else in this file assumes you can be read.

### Have these pasted and ready

Typing `oc get inferenceservice -n devspaces-demo` on stage is thirty seconds of
nothing happening. Put them in a scratch file and copy from it.

```bash
oc get pods -n <username>-devspaces
oc get devworkspace -n <username>-devspaces
oc get checluster devspaces -n openshift-devspaces -o yaml | grep -A5 Inactivity
oc get inferenceservice -n devspaces-demo
oc get networkpolicy -n devspaces-demo
oc get secrets -n <username>-devspaces | grep -i gitlab
```

---

## Act 1, framing (4 min)

No slides, no product, no browser yet. You are only setting up the question.

**Ask the room, and wait for an answer.** Do not fill the silence.

> How long from a new developer's first day to their first merged commit?

Someone will say a number. It is usually two to six weeks. Follow with:

> And how much of that is waiting for access versus actually setting up the
> machine?

**Then name the cost they have not counted:**

> Every one of those environments is slightly different. The difference does not
> show up on day one. It shows up at 2am in an incident, when the thing that
> reproduces on one laptop does not reproduce on another, and nobody can say
> why.

**Then go straight to the browser.** No agenda slide. The demo is the argument.

If the room is quiet and nobody answers the opening question, do not push it.
Say "in most banks I work with it is somewhere between two and six weeks" and
move on. A silent room is not a hostile one, but a second unanswered question
makes it one.

---

## Act 2, the first sixty seconds (5 min)

The whole act is one claim: a developer gets a working environment without doing
anything. Narrate what the developer experiences, nothing else. Do not say the
word "devfile" yet. Act 3 is where you pull the cover off, and it lands harder
if they have already watched it work.

### Steps

1. Dev Spaces dashboard, **Create Workspace**.
2. Paste the **payments-service** URL into the Git repository field.
3. **Create & Open**.

While it starts, talk. You have between one and two minutes, and you should know
which because you measured it with `scripts/rehearse.sh`.

> What is happening now is a pod being scheduled on the cluster. The container
> image already has Java 21 and Maven in it. Nobody is downloading a JDK, and
> nobody is filing a ticket to get one approved.

4. Workspace opens. **Point out the project is already cloned.** Do not skip
   this, it is easy to take for granted and it is half the point.
5. Open a terminal in the IDE. Run the build so they see it work:

```bash
mvn -B clean package -DskipTests
```

6. Then the run command, from the IDE's command palette or the terminal:

```bash
mvn -B spring-boot:run
```

7. Dev Spaces raises a notification that a service is listening on 8080. **Open
   it.** Append `/api/payments` to the URL.

You get two payment records back as JSON. That is the service running inside the
cluster, reachable over a URL that did not exist ninety seconds ago.

### The live edit

Back in the IDE, open:

```
src/main/java/com/example/demo/PaymentController.java
```

Add a third record to the `list()` method. Type it, do not paste, they should
see it is a real editor:

```java
Map.of("id", "PMT-1003", "amount", 4200.00, "currency", "NZD", "status", "HELD")
```

Stop the running process, run it again, refresh the browser tab. Three records.

### Land it

> No JDK install. No Maven settings file. No proxy configuration. No access
> request. And the repository that came from is GitLab running in this cluster,
> so nothing you just watched touched the public internet.

Say that last sentence even though nobody asked. It plants the flag you pick up
in act 3, and for the security people in the room it is the first moment they
start paying attention.

### If it is slow

You did not run `smoke.sh`, or the cluster garbage-collected the image overnight.
Do not apologise repeatedly, and do not stare at the screen. Fill it:

```bash
oc get checluster devspaces -n openshift-devspaces -o yaml | grep -A5 Inactivity
```

> While that comes up, this is worth seeing. Workspaces idle out on a timer the
> platform team sets. That number is a real cost control and someone has to own
> it, which is a conversation I want to come back to at the end.

You have just turned dead air into act 7 setup.

---

## Act 3, peel the layer back (6 min)

Now say "devfile". They have seen it work, so this is an explanation rather than
a promise.

Open `devfile.yaml` in the running workspace and walk it top to bottom. Four
stops, in this order.

### Stop 1: the image (spend the most time here)

```yaml
image: registry.access.redhat.com/ubi9/openjdk-21:latest
```

> This line is the governance hinge, and it is the most important line in the
> demo. In your environment that is not a public Red Hat tag. It is your
> internally built image, scanned by your pipeline, with your CA bundle already
> in the trust store and your Nexus or Artifactory settings already configured.
>
> Your platform team owns it. So when a CVE lands in the JDK, that is one
> rebuild, and every developer picks it up the next time they start a workspace.
> Compare that to chasing four hundred laptops and hoping.

Pause there. That is the line the platform lead repeats to their CIO afterwards.

### Stop 2: the endpoints

```yaml
endpoints:
  - name: http-payments
    targetPort: 8080
    exposure: public
  - name: debug
    targetPort: 5005
    exposure: none
```

> That is where the URL came from. And notice `exposure`. The debug port is
> declared, so the tooling knows about it, but it is not routable outside the
> workspace. That is a control, not a convenience.

### Stop 3: the commands

> Build, run, test and debug are written down, in the repository, next to the
> code. Not in a README that went stale, not in one person's shell history. When
> the way to build this service changes, that is a merge request.

### Stop 4: what is not there

> There is no `projects` block in this file. Dev Spaces clones whatever
> repository the workspace was created from, so the devfile never names its own
> remote. That is what makes it portable: this exact file works against your
> Bitbucket Data Center or your GitHub Enterprise with no changes. Which matters,
> because the thing you are adopting should not be the thing that ties you to a
> particular SCM.

### Then drop to the terminal

```bash
oc get pods -n <username>-devspaces
```

> It is a pod. There is no new runtime here, no new thing to learn to operate.
> Your existing cluster monitoring already sees this. Your existing quota already
> applies to it.

### Say the trade-off out loud, unprompted

This buys more credibility than anything else in the demo, and it is usually the
platform team who can kill the deal.

> I should be straight with you about what I have just done. I have moved cost
> from the laptop to the cluster. That needs node capacity planning and an idle
> timeout policy, and if you get the second one wrong you will pay for idle pods
> all weekend. It is a real trade, not a free win, and someone has to own that
> number.

### Bonus: the supply chain story (cut this first if you are long)

Only if act 3 is running to time.

> One real example, from building this demo. MinIO deleted their public
> container images from Docker Hub on the 11th of September, and gated Quay nine
> days ago. This demo broke. Every tag now refuses anonymous pulls, so pinning a
> version would not have saved me. And the last free community build has an
> unpatched authentication bypass rated 8.8.
>
> Anyone pulling that image straight into a build had a broken pipeline that
> Friday, and some of them shipped the vulnerable version. That is the argument
> for an internal registry and a team that curates images, and I did not have to
> invent it.

---

## Act 4, local IDE and the handoff (6 min)

This act exists to kill one specific objection, and you should name it yourself
before anyone raises it:

> The objection I get at this point is always the same. "Our senior developers
> will never give up IntelliJ." So let me deal with that now.

### Read this before you rehearse it

**The editor is chosen when the workspace is created, and you cannot attach a
desktop IDE to a workspace that was created with the browser editor.** There is
no "connect desktop VS Code" button on a running browser workspace. Newer
dashboards can change the editor on a **stopped** workspace, but that is not
something to rely on live, and it still is not a live attach.

So act 4 is **three workspaces from the same repository**, each created with a
different editor, all pre-created before the room fills. That is not a
workaround. It is a better demo: you can put them side by side instead of
narrating a sequence, and the argument gets stronger rather than weaker.

What you have to do once, beforehand, per environment:

| Editor          | Created as                           | Installed locally                                                                                                  |
| --------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| Browser         | `VS Code - Open Source`              | nothing                                                                                                            |
| Desktop VS Code | `Visual Studio Code (desktop) (SSH)` | `redhat.devspaces-remote-ssh`, plus Microsoft `Remote - SSH` (or `jeanp413.open-remote-ssh` on a Code-based build) |
| JetBrains       | `IntelliJ IDEA Ultimate`             | JetBrains Gateway, plus the "Gateway provider for OpenShift Dev Spaces" plugin, and `oc` logged in locally         |

**JetBrains Gateway needs a paid JetBrains licence.** The Gateway editors are the
commercial IDEs: IntelliJ IDEA Ultimate, WebStorm, PyCharm Professional,
RubyMine, CLion. There is no Community option. If you do not have a licence,
**act 4 is VS Code only** and you cover JetBrains verbally. Sort this out now,
not the night before.

### Connecting local VS Code, the actual procedure

This is not obvious from the product and the landing page instructions are, in
Red Hat's own words, not trivial. Do it once, well before the session.

**Check your Dev Spaces version first.** The extension must be newer than the
Dev Spaces it talks to.

```bash
oc get csv -n openshift-operators | grep -i devspaces
```

| Dev Spaces | Minimum extension version |
| ---------- | ------------------------- |
| 3.27       | 0.3.1                     |
| 3.28       | 0.4.0                     |
| 3.29, 3.30 | 0.5.0                     |

**One-time local setup.** In your desktop VS Code, install both:

- `ms-vscode-remote.remote-ssh` (Microsoft Remote - SSH). On a Code-based build
  such as VSCodium use `jeanp413.open-remote-ssh` instead; Cursor has its own
  and needs nothing extra.
- `redhat.devspaces-remote-ssh` (Dev Spaces Local/Remote Support - SSH).

`oc` is bundled inside the Red Hat extension on the common platforms, so you do
not need to install it separately for this.

**Create the workspace with the right editor, and force a NEW one.**

This is the trap, and it will cost you an hour if nobody warns you. **Pasting a
repository URL that already has a workspace opens the existing workspace.** It
does not create a second one, and your editor selection is silently ignored,
because nothing is being created for it to apply to. You pick
`Visual Studio Code (desktop) (SSH)`, the browser IDE opens, and it looks as
though the product ignored you.

Act 4 needs three workspaces from one repository, so this is not an edge case
here, it is the whole act. Use the `new` URL parameter:

```
https://devspaces.apps.<cluster>/#https://gitlab.apps.<cluster>/platform-engineering/payments-service?new
```

The repository URL goes after the `#`. Add further parameters with `&`. Then
pick the editor in the dashboard as normal.

If you would rather not use URL parameters, delete the existing workspace first
and the selector behaves as you expect:

```bash
oc get devworkspace -n <username>-devspaces
oc delete devworkspace <name> -n <username>-devspaces
```

**What success looks like:** a workspace created with the desktop SSH editor
runs an sshd inside the dev container and, instead of an IDE, opens a **landing
page** at port 3400 carrying the connection details and a `vscode://` URI. If
you get the browser IDE, you reopened the old workspace. Check which editor the
workspace actually got:

```bash
oc get devworkspace <name> -n <username>-devspaces -o yaml | grep -i -A3 contributions
```

**Then connect, one of three ways.** Use the third for the demo.

1. **Click the `vscode://` URI on the landing page.** Dev Spaces 3.28 and later
   publish one. Clicking it, or pasting it into the "Connect to Dev Spaces"
   prompt in VS Code, launches your local editor and connects it.

2. **Paste the landing page URL.** In VS Code open the **Remote Explorer** view,
   click one of the "Connect to Dev Spaces" icons, and give it the landing page
   URL, which looks like:

   ```
   https://<cluster>/<username>/<workspace-name>/3400/
   ```

   It redirects you through the cluster login page, then connects. Deprecated,
   but it still works and it is the fallback if the URI does nothing.

3. **Pick it out of Remote Explorer.** Log in locally first:

   ```bash
   oc login --token=... --server=...
   ```

   Your workspaces then appear by themselves under the **SSH** category in
   Remote Explorer. Click one to connect in this window or a new one. No URLs,
   no pasting.

**Use the third one on stage.** It is one click, there is nothing to paste, and
it makes a point the other two do not: the developer's own editor lists the
governed environments available to them, the way it would list any other remote
host. If it is empty, you are not logged in locally, which is the first thing to
check.

**Then open the folder.** A fresh Remote-SSH connection lands you in the
container with no folder open, which looks like a failed connection and is not
one. File, Open Folder:

```
/projects/payments-service
```

Dev Spaces clones into `/projects/<repo-name>`, and `mountSources: true` in the
devfile is what puts it there. `ls /projects` from the connected terminal
confirms it. VS Code remembers the folder per SSH host, so do this once
beforehand and reconnecting goes straight back to it.

Worth considering whether to do it live. Opening a path that has never existed
on your laptop, from your own editor with your own theme, is a clean ten seconds:

> That path is inside the pod. I am opening a folder that has never existed on
> this laptop.

Pre-open it if you are tight on time. The act survives either way.

### Scripting the pre-creation

Once you have created one by hand, read the editor id back off the workspace
rather than guessing it:

```bash
oc get devworkspace <name> -n <username>-devspaces -o yaml | grep -i -A3 contributions
```

### Steps

Have all three workspaces already running. Act 4 should contain no workspace
starts at all.

1. Start in the **browser** workspace, the one from acts 2 and 3. Nothing new to
   show, it is your reference point.
2. Switch to **desktop VS Code**, already connected. Show your own theme,
   keybindings and extensions.
3. In its terminal, prove where the shell actually is:

```bash
hostname
oc whoami
ls
```

> That is my editor, my keybindings, my extensions, on my machine. And that
> shell is a pod in the cluster. The source is not on my laptop, and it never
> was. If I lose this machine tonight, I have lost a text editor.

4. Switch to **JetBrains**, already connected to its own workspace.

> Same repository. Same devfile. Same container image the platform team owns.
> Different editor, because that is a preference and not a control.

5. Optional, and good if the room is technical: bring up the dashboard showing
   all three workspaces listed against the same repository URL.

### Land it

> The environment is the governed thing. The editor is a personal preference.
> Your platform team stops having to have an opinion about which IDE people use,
> and your developers stop having to argue for one. Nobody has to win that
> argument, which is the only way it ever ends.

### Be straight about the cost

Someone technical will work out that these are three separate workspaces, and it
is much better if you say it first.

> To be clear about what you are seeing: each of these is its own workspace and
> its own pod. The editor is part of the environment definition, so it is chosen
> when the workspace is created rather than swapped underneath a running one.
> In practice a developer picks their editor once and never thinks about it
> again. It does mean three pods rather than one while I show you all three,
> which is a capacity question and goes back to the quota point from earlier.

### Failure mode

You are not starting anything live, so the failure mode is a client that has
dropped its connection while you were in act 3. Do not reconnect on stage.

> I have this working in the browser, let me come back to the desktop client at
> the end if we have time.

Then move on immediately. Do not explain, do not retry. Rehearse saying that
line once out loud so it sounds unbothered.

---

## Act 5, author a devfile live (8 min)

Follow `docs/DEVFILE-LIVE-BUILD.md`. It has the four passes, what to say at each,
and the finished file if you need to paste rather than type.

This is the act to rehearse most. It proves the whole thing is code, and it is
the one most likely to go sideways if you improvise.

**Reset afterwards.** `scripts/reset.sh`, or `ledger-service` is no longer
devfile-free and act 5 does not work next time.

---

## Act 6, Ansible, identity and in-cluster AI (7 min)

Three things, none of them long. If you are behind, cut the AI segment: it is
the most impressive and the least load-bearing.

### Ansible (2 min)

1. Create a workspace from the **ansible-automation** URL.
2. Open `playbooks/site.yml`. The language server gives you module docs inline,
   so hover a module and show it.
3. In the terminal:

```bash
ansible-lint playbooks/site.yml
```

4. Then run it, because a passing lint is less interesting than working content:

```bash
ansible-playbook playbooks/site.yml
```

**Optional and better if you can do it smoothly:** break something live. Change
`ansible.builtin.command` to `ansible.builtin.shell` in the "Confirm the
artefact exists" task and watch the editor flag it before you run anything. That
demonstrates the authoring loop rather than a CLI, which is the actual point.

> Dev Spaces is not only for application developers. Your automation content is
> code, it goes through review, and it deserves the same governed authoring
> environment. For most of the banks I work with this is the team that gets
> value first, because their tooling setup is usually the worst in the building.

### Per-user OAuth (3 min, the strongest security content in the demo)

You need to be a first-time user, so **open an incognito window**. If you are
already authorised everywhere, this shows nothing.

1. Incognito, go to the dashboard, log in.
2. Create a workspace from the payments URL.
3. Dev Spaces redirects to GitLab. **Authenticate as yourself.** Authorise the
   Dev Spaces application.
4. The workspace clones and starts.

Say this while it happens:

> Notice what did not occur. I was not handed a credential to paste anywhere.
> Dev Spaces never saw my password. What it is holding is an OAuth token scoped
> to me, stored in the cluster, not on a laptop. My commits will attribute to me.
> And when I leave, that access dies with my identity in the directory, rather
> than whenever somebody remembers to go looking for a shared service account.

Then show where it lives:

```bash
oc get secrets -n <username>-devspaces | grep -i gitlab
```

**Then make the contrast explicit:**

> The version of this problem most organisations have no clean answer to is a
> cloned repository on a departing contractor's laptop. This is that answer.

If someone asks whether this is a demo shortcut: it is the same mechanism
against Bitbucket Data Center, GitHub Enterprise and Azure DevOps. Those four
are the supported providers. Anything else needs a token in a secret, which
works but gives you one shared identity instead of per-user ones.

### In-cluster AI (2 min)

**Do this in the BROWSER workspace, not the desktop one.** That is not a
presentation preference, it is the whole substance of the segment, and the next
subsection explains why.

1. In the browser IDE, open the Continue panel and ask it something about the
   code, or start a method signature and let it complete. Do not narrate it, let
   them watch.
2. Then:

```bash
oc get inferenceservice -n devspaces-demo
oc get networkpolicy -n devspaces-demo
```

> That model is a workload in this cluster, with a URL, a replica count and a
> GPU request. The network policy says developer workspaces can reach it and
> nothing else can.

3. Show the wiring, because it is the point and it is four lines:

```bash
oc get devworkspace <name> -n <username>-devspaces -o yaml | grep -A3 AI_BASE_URL
```

> The platform team put that endpoint in the devfile. The developer did not
> choose it and cannot quietly point it somewhere else without that being a
> change to a file in a repository, reviewed like any other.

**The line:**

> On a laptop, "developers must only use the approved assistant" is a policy you
> are trusting four hundred people to follow. In a workspace the platform team
> defines, it is an environment variable in a devfile they own, pointing at an
> endpoint only workspaces can reach, on hardware you control. You have turned a
> policy statement into a configuration fact.

### Where that claim stops being true, and say it yourself

**This is the most valuable ninety seconds in the demo for a CISO, and the
easiest to get caught out by.** In act 4 you celebrated bringing your own editor
with your own extensions. Bringing your own extensions means bringing your own
assistant. Copilot, signed into a developer's personal GitHub account, runs
happily in a desktop IDE attached to the workspace, sends context over the
developer's own network, and the platform team's devfile has nothing to say about
it.

So the honest position is a boundary, not a blanket:

> I want to be precise about this, because it matters and it is the sort of thing
> that gets discovered in an audit rather than a demo. In the browser IDE, the
> toolchain is the platform team's: the extensions come from the devfile and your
> own registry, the assistant endpoint is set by the devfile, and egress is
> controlled by network policy. That is a configuration fact.
>
> In the desktop IDE, it is not. The editor is on the developer's machine, so
> their extensions and their network come with it. If they have Copilot signed
> in, it works, and nothing in this cluster prevents it. What you get from Dev
> Spaces there is that the source and the credentials stay in the cluster, which
> is still most of the value, but assistant control is not part of it.
>
> That is a real decision for you rather than a gap in the product. Some teams
> get the browser IDE and a governed toolchain. Some get the desktop IDE and you
> handle assistants through endpoint policy, the way you already handle every
> other application on that laptop.

Say that unprompted. Someone will otherwise work it out three slides later and
then everything you claimed becomes suspect.

### Two more honest notes, if asked

**Extensions come from Open VSX over the internet by default.** That sits awkwardly
beside the "nothing leaves the data centre" story, and the answer is that a bank
runs a private Open VSX registry, curated the same way they curate base images.
It is the same argument as act 3, one layer up, and worth conceding before it is
pointed out.

**Prompt logging and retention** will come up. Good sign. Serving gives you a
place to put that control; what gets logged is a decision their model serving
team makes, not something Dev Spaces decides for them.

---

## Act 7, operating model close (5 min)

No demo. Close the laptop lid if you can do it without it being a performance.

Put these to the room rather than answering them. The goal is for them to
realise they do not currently have answers, not for you to supply yours.

- Who owns the devfile catalogue, and what is the SLA on approving a new stack?
- Who owns the base images, and what happens the day a JDK CVE lands?
- Who owns model serving? Is that the same team? (It is not.)
- How is quota set, and whose budget does it come out of?
- Which teams go first, and what makes them a good pilot?

Let them talk. If the room starts arguing about who owns the catalogue, that is
the best possible outcome and you should get out of the way.

**Close:**

> Dev Spaces is a platform product, not a tool you install. It needs an owner, a
> backlog and a funding line. Treated as a tool, it will drift, and in eighteen
> months people will be back on their laptops and you will have paid for both.
> Treated as a product, it is the cheapest environment governance you will ever
> buy.

**Then stop talking.** The silence after that is where the real conversation
starts, and the temptation to fill it is strong. Do not.

---

## The three things to rehearse

You will not get time to rehearse everything. In priority order:

1. **Act 5.** Typing live in front of people is the hardest thing here and the
   easiest to fix with practice.
2. **Act 2's dead air.** Know exactly what you say while the workspace starts,
   because you cannot improvise into silence.
3. **The act 4 abandon line.** Say it out loud once so it sounds calm rather
   than flustered when you need it.

## Where this goes wrong

| It happens                                    | Do this                                                                                                        |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Workspace slow to start                       | The idle timeout filler in act 2. Never apologise twice.                                                       |
| Desktop IDE will not attach                   | The abandon line. Move on inside ten seconds.                                                                  |
| AI completion never returns                   | Skip it. Go to `oc get inferenceservice` and make the governance point without the completion; it still lands. |
| GitLab asks for credentials unexpectedly      | You are not in incognito, or the handshake was never done. Do it in act 6 deliberately instead.                |
| Someone derails act 2 with a devfile question | "That is exactly where I am going next, give me sixty seconds." Then actually go there.                        |
| You are ten minutes over at act 5             | Cut the AI segment and the supply chain story. Never cut act 7.                                                |

# Internal Git (Gitea Overlay)

On by default. Gitea is the demo's SCM: the samples are published into it as
standalone repositories and every workspace clones from it over cluster-internal
networking. Nothing in the demo reaches the internet, not even at bootstrap.

Turning it off (`DEPLOY_GITEA="false"`) leaves you with no repository URLs to
create workspaces from, so there is rarely a reason to.

## Say the constraint out loud

Gitea is not what your customers run. They run Bitbucket Data Center or GitHub
Enterprise. Name that in the room before anyone else does:

> This is Gitea because it has to fit in a demo environment I get for five days.
> In your data centre this is Bitbucket. The pattern is identical, and that is
> what I want you to look at.

An audience that catches you glossing over it will discount everything else you
say. An audience you tell up front will engage with the pattern instead of the
product. This costs you fifteen seconds and buys you the rest of the session.

## What it actually demonstrates

Two things, and they are worth separating.

**The code never leaves the data centre.** The workspace clones over
cluster-internal networking. No public internet in the path. For a bank this is
often the difference between a pilot and a conversation that goes nowhere,
particularly for contractors and third parties.

**The credential is provisioned, not typed.** `scripts/gitea-credentials.sh`
puts a labelled secret into the developer's namespace. Dev Spaces mounts it into
every workspace. The developer clones and pushes without ever seeing a token,
and there is nothing on a laptop to leak.

That second point is the one to spend time on. The honest framing is that this is
already how most banks run it: a service-account token provisioned by the
platform team against Bitbucket Data Center. You are not showing a workaround,
you are showing the pattern they recognise. Revocation becomes a secret rotation
rather than a fleet-wide endpoint problem.

## Where the demo is not the real thing

Be ready for these, because a good architect in the room will spot them.

- **One shared account.** Real deployments give each developer their own
  identity, so commits attribute correctly and access follows the person.
  Covered by the OAuth talk track below.
- **Namespace scope.** The secret is applied to one user namespace. At scale you
  replicate it with an external secrets operator, not a shell script.
- **`sslVerify = false`** in the workspace gitconfig, because the Route uses the
  cluster's default certificate. In their environment the corporate CA is in the
  workspace image and this line disappears. That connects back to the act 3
  point about internally built base images, so it is worth using rather than
  hiding.

## The OAuth talk track

Raise this yourself, in act 6, right after the credential injection. Do not wait
to be asked.

Dev Spaces ships first-class OAuth providers for GitHub, GitHub Enterprise,
GitLab, Bitbucket and Azure DevOps. Gitea is not one of them, which is why this
demo uses a token in a secret. **What you are running in production is the better
version, not the compromise.**

Roughly what to say, in your own words:

> What I have just shown you is a service-account token, provisioned by the
> platform. That works, and plenty of shops run exactly that. But it is the
> weaker of the two options, and I want to be straight with you about why.
>
> Against your Bitbucket, Dev Spaces would use OAuth. The developer authenticates
> once, as themselves. The token is scoped to them, commits attribute to them,
> and when they leave, their access goes with them. No shared account, no token
> sitting in a secret that four teams know about.
>
> I could not show you that today because Gitea is not one of the supported
> providers. It is a limitation of my demo environment, not of the product.

### Why this is worth saying

Three reasons, and they compound.

1. **It is the truth, and the room can check it.** Someone will know the provider
   list. Being the one who raises it costs nothing; being caught glossing over it
   costs the session.
2. **The stronger claim is the true one.** You get to say "the real thing is
   better than what I just showed you", which almost never happens in a demo.
   That lands harder than any feature would.
3. **It moves the conversation to their environment.** Once you have named
   Bitbucket or GitHub Enterprise, the next question is usually "so how would
   that work for us", which is exactly where you want to be.

### The follow-ups you will get

**"So what happens when someone leaves?"** With OAuth, their token dies with
their identity in your IdP. That is the answer they want, and it is a genuinely
strong one against the laptop status quo, where a cloned repo on a departing
contractor's machine is a real problem nobody has a clean answer for.

**"Which identity provider does it use?"** Whatever OpenShift is already using,
so their existing OIDC or SAML integration. This is not a new identity silo, and
that matters to whoever owns IAM.

**"Can we still use service accounts for automation?"** Yes, and they should.
OAuth is for humans, tokens are for pipelines. Both patterns are supported and
they answer different problems.

**"Where is the OAuth token stored?"** In the user's namespace on the cluster,
not on the endpoint. Same argument as before, just with better provenance.

### If you are running without Gitea

The same talk track works, shortened. In act 3, when you are on the devfile's
`projects` block: "this points at my GitHub because I am on a public cluster.
In your environment it is your Bitbucket, the developer authenticates once
through OAuth against the identity provider OpenShift already uses, and no
credential ever reaches a laptop." Ten seconds, and you have made the point
without standing anything up.

## Running it

```bash
# demo.env
DEPLOY_GITEA="true"
GITEA_ORG="platform-engineering"
GITEA_ADMIN_USER="platform-admin"
GITEA_ADMIN_PASSWORD="<regenerate per environment>"
```

```bash
./scripts/up.sh                     # stands up Gitea, then seeds it
# start a workspace once so your user namespace exists
./scripts/gitea-credentials.sh      # inject the credential
# restart the workspace to pick it up
```

To re-publish after editing a sample, without a full bootstrap:

```bash
./scripts/seed-gitea.sh
```

`scripts/seed-gitea.sh` pushes straight from your working tree over the Gitea
Route, rendering the AI endpoint into each devfile as it goes. Re-run it any time
you change a sample: it is a force push, so the repos always match your tree.
That makes iterating on a devfile a fifteen second loop instead of a
commit-push-wait cycle.

Three standalone repos, each with its devfile at the root:

- `payments-service` — acts 2 to 4
- `ansible-automation` — act 6
- `ledger-service` — act 5, still deliberately without a devfile

The devfiles carry no `projects` block. Dev Spaces clones the repository the
workspace was created from, so declaring it again is redundant, and pinning a
remote is what ties a devfile to one SCM. It also means these devfiles work
unchanged against Bitbucket or GitHub Enterprise.

Regenerate `GITEA_ADMIN_PASSWORD` per environment. Do not carry one between
customers, and do not commit `demo.env`.

## Where it fits in the demo

Do not give this its own act. Fold it into what you are already doing:

- **Act 2**, create the workspace from the Gitea URL rather than GitHub. One
  sentence of framing, then carry on as normal.
- **Act 3**, when you reach the container image and the governance point, note
  that the Git remote is internal for the same reason the image is.
- **Act 6**, the credential injection. Open a terminal in the workspace, `git
push` a small change, and point out that nothing was typed. Then show the
  secret with `oc get secret`. Ninety seconds, high impact.

## If it breaks

| Symptom                             | Do this                                                                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Seed Job fails                      | `oc logs job/gitea-seed -n <ns>`. Usually the admin user was not created; check the postStart hook in the gitea pod logs. |
| Workspace clone fails on TLS        | The gitconfig ConfigMap did not mount. Restart the workspace after running `gitea-credentials.sh`.                        |
| Dashboard cannot reach the repo URL | You used the Service DNS somewhere instead of the Route. The browser cannot resolve cluster-internal DNS.                 |
| Running short on time               | Set `DEPLOY_GITEA="false"` and run from GitHub. The architectural point survives being asserted rather than shown.        |

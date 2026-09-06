# Curated Devfile Registry

Two ways to use this in the demo, in increasing order of effort.

**Option A, lowest risk, recommended for a 40 minute slot.**
Use the Dev Spaces dashboard "Create Workspace" page and paste the raw Git URL of
a sample. Then open `registry/index.json` in the IDE and talk to it as the
*intended* end state: a catalogue the platform team owns, versions and approves.
You get the whole governance argument with none of the moving parts.

**Option B, full build.**
`scripts/build-registry.sh` builds this directory into a container image, pushes
it to the internal registry, and patches the CheCluster to consume it as an
external registry. Adds roughly 6 minutes to bootstrap and one more failure mode.
Only do this if the audience is a platform team who will ask to see it.

The talking point either way: a new approved stack is a pull request against this
repo, reviewed by the people accountable for it. Not a ticket, not a wiki page,
not a laptop setup guide that went stale in March.

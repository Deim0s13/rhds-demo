# Gitea image for OpenShift

Built in-cluster by `scripts/up.sh` via the BuildConfig in
`overlays/gitea/00-build.yaml`. No external registry, no push credentials.

The upstream image fails under `restricted-v2`. See the Containerfile comments
for why, and `docs/INTERNAL-GIT.md` for how to use it as a talking point in
act 3.

Evidence, if anyone asks how this was determined. Simulating what OpenShift does
(arbitrary UID, GID 0):

    podman run --rm -u 1000670000:0 docker.io/gitea/gitea:1.22
    # s6-svscan: fatal: unable to open .s6-svscan/lock: Permission denied

    podman run --rm -u 1000670000:0 docker.io/gitea/gitea:1.22-rootless
    # mkdir: can't create directory '/var/lib/gitea/git': Permission denied

Same test against this image should start normally.

# Act 5: Authoring a Devfile Live

Eight minutes. Build it in four passes so the audience watches the shape emerge
rather than reading a finished file. Talk while you type; the pauses are the
point.

Target file: `samples/bare-app/devfile.yaml`. It is not in Git on purpose.

## Pass 1, the header and the container (2 min)

```yaml
schemaVersion: 2.2.0
metadata:
  name: ledger-service

components:
  - name: tools
    container:
      image: registry.access.redhat.com/ubi9/openjdk-21:latest
      memoryLimit: 4Gi
      cpuLimit: 2000m
      mountSources: true
```

**Say:** "This is the whole governance story in six lines. That image reference
is where your platform team puts its foot down. In your bank it is not a public
UBI tag, it is your scanned internal image with your CA bundle in it. When a CVE
lands, you rebuild once, and every developer picks it up on their next workspace
start. Compare that to chasing 400 laptops."

## Pass 2, the commands (2 min)

```yaml
commands:
  - id: build
    exec:
      component: tools
      commandLine: "mvn -B clean package -DskipTests"
      workingDir: ${PROJECT_SOURCE}
      group:
        kind: build
        isDefault: true
  - id: run
    exec:
      component: tools
      commandLine: "mvn -B spring-boot:run"
      workingDir: ${PROJECT_SOURCE}
      group:
        kind: run
        isDefault: true
```

**Say:** "How to build this service is now written down, in the repo, next to the
code. Not in a README that is out of date, not in someone's shell history. If it
changes, that is a pull request."

## Pass 3, the endpoint (1 min)

```yaml
      endpoints:
        - name: http-ledger
          targetPort: 8080
          exposure: public
          protocol: https
```

Indent this under `container`, alongside `mountSources`.

**Say:** "That gives the running service a URL. Note `exposure`. It is a real
control, not a convenience. Set it to `none` and the port exists inside the
workspace only, which is what you want for a debug port."

## Pass 4, the project (1 min)

```yaml
projects:
  - name: ledger
    git:
      remotes:
        origin: "https://github.com/<your-org>/rhds-demo.git"
      checkoutFrom:
        revision: main
    subDir: samples/bare-app
```

**Say:** "And now anyone with this URL gets this environment. That is the whole
onboarding process."

## Then start it

Dashboard, create workspace from the repo URL, watch it come up, run it, hit the
endpoint. Roughly 90 seconds if the image is warm, which is why `smoke.sh` exists.

## Then make the registry point (2 min)

Open `registry/index.json` beside it.

**Say:** "What I just did by hand is what a platform team does once, properly,
and publishes. This is a catalogue of approved stacks. A team wanting a new one
raises a pull request against this repo. Reviewed by the people accountable for
it, versioned, auditable. That is the difference between a tool and a platform
product."

## The finished file, for paste-in-a-hurry

```yaml
schemaVersion: 2.2.0
metadata:
  name: ledger-service
projects:
  - name: ledger
    git:
      remotes:
        origin: "https://github.com/<your-org>/rhds-demo.git"
      checkoutFrom:
        revision: main
    subDir: samples/bare-app
components:
  - name: tools
    container:
      image: registry.access.redhat.com/ubi9/openjdk-21:latest
      memoryLimit: 4Gi
      cpuLimit: 2000m
      mountSources: true
      endpoints:
        - name: http-ledger
          targetPort: 8080
          exposure: public
          protocol: https
commands:
  - id: build
    exec:
      component: tools
      commandLine: "mvn -B clean package -DskipTests"
      workingDir: ${PROJECT_SOURCE}
      group: {kind: build, isDefault: true}
  - id: run
    exec:
      component: tools
      commandLine: "mvn -B spring-boot:run"
      workingDir: ${PROJECT_SOURCE}
      group: {kind: run, isDefault: true}
```

Run `scripts/reset.sh` afterwards. It deletes this file so the next run starts clean.

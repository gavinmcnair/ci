# GitHub Actions Self-Hosted Runners — Setup Plan

## Goal

Set up self-hosted GitHub Actions runners on both machines and prove they work
with a test multi-arch Docker build — all inside this CI repo. Once the runners
and workflow are validated, the gstreamer repo adopts the same workflow pattern.

## Phases

1. **Runner setup** — get both containers running and registered with GitHub
2. **Test workflow** — a `.github/workflows/test-build.yml` in THIS repo that
   builds a trivial multi-arch Docker image, pushes arch-tagged images, creates
   a manifest, and verifies it pulls correctly on both architectures
3. **Adopt in gstreamer** — copy the proven workflow pattern to `gavinmcnair/gstreamer`
   with the real Dockerfile and `make test`

## Architecture

Two runners, one per architecture, both running GitHub's official runner in Docker containers:

| Runner | Host | Architecture | Runtime |
|--------|------|-------------|---------|
| amd64 | TrueNAS Xeon 64-core, 192GB | linux/amd64 | TrueNAS App (Docker) |
| arm64 | Mac Studio M3 Max, 64GB | linux/arm64 | Docker Desktop container |

Both runners register with GitHub and pick up jobs matching their architecture labels.
No CI server to maintain — GitHub coordinates everything.

## How It Works

1. Each runner container connects to GitHub via HTTPS (outbound only, no inbound ports)
2. GitHub dispatches jobs based on `runs-on:` labels in workflow files
3. Runner pulls the repo, executes the workflow steps, reports results
4. Docker-in-Docker (DinD) gives each runner the ability to build images

## Prerequisites

- GitHub Personal Access Token (PAT) with `repo` scope, or a fine-grained token with "Administration" read/write on the target repos
- Docker running on both machines
- Outbound HTTPS access from both machines to github.com

## Runner Setup

### Step 1: Create GitHub PAT

1. Go to https://github.com/settings/tokens
2. Create a **fine-grained personal access token**
3. Scope it to your repos (gavinmcnair/gstreamer, gavinmcnair/tvproxy, etc.)
4. Permission: **Administration: Read and write** (needed to register runners)
5. Save the token — you'll use it as `GITHUB_TOKEN` below

Alternatively, use an **organization-level runner** if you create a GitHub org,
or per-repo registration tokens from Settings → Actions → Runners → New self-hosted runner.

### Step 2: TrueNAS (amd64)

TrueNAS SCALE runs Docker via its app system. Create a custom Docker app:

**Docker Compose (or TrueNAS app equivalent):**

```yaml
# File: docker-compose.amd64.yml
version: "3.8"

services:
  github-runner:
    image: myoung34/docker-github-actions-runner:latest
    container_name: github-runner-amd64
    restart: always
    environment:
      - RUNNER_NAME=amd64
      - RUNNER_SCOPE=repo
      - REPO_URL=https://github.com/gavinmcnair/gstreamer
      - LABELS=self-hosted,linux,amd64
      - ACCESS_TOKEN=${GITHUB_TOKEN}
      - RUNNER_WORKDIR=/tmp/runner
      - DOCKER_ENABLED=true
      - DOCKERHUB_LOGIN=${DOCKERHUB_USERNAME}
      - DOCKERHUB_PASSWORD=${DOCKERHUB_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - runner-work-amd64:/tmp/runner
    security_opt:
      - label:disable

volumes:
  runner-work-amd64:
```

**To deploy on TrueNAS:**

Option A — TrueNAS custom app:
1. TrueNAS UI → Apps → Discover Apps → Custom App
2. Enter the container config from above (image, env vars, volumes)
3. Map `/var/run/docker.sock` as a host path volume

Option B — Docker compose via TrueNAS shell:
1. SSH into TrueNAS
2. Create `/mnt/pool/apps/github-runner/docker-compose.yml` with the above
3. Create `/mnt/pool/apps/github-runner/.env` with your tokens
4. `docker compose up -d`

### Step 3: Mac Studio (arm64)

Docker Desktop on macOS runs a Linux VM, so the runner container is linux/arm64 natively.

```yaml
# File: docker-compose.arm64.yml
version: "3.8"

services:
  github-runner:
    image: myoung34/docker-github-actions-runner:latest
    container_name: github-runner-arm64
    restart: always
    environment:
      - RUNNER_NAME=arm64
      - RUNNER_SCOPE=repo
      - REPO_URL=https://github.com/gavinmcnair/gstreamer
      - LABELS=self-hosted,linux,arm64
      - ACCESS_TOKEN=${GITHUB_TOKEN}
      - RUNNER_WORKDIR=/tmp/runner
      - DOCKER_ENABLED=true
      - DOCKERHUB_LOGIN=${DOCKERHUB_USERNAME}
      - DOCKERHUB_PASSWORD=${DOCKERHUB_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - runner-work-arm64:/tmp/runner
    security_opt:
      - label:disable

volumes:
  runner-work-arm64:
```

**To deploy:**

```bash
cd /Users/gavinmcnair/claude/ci
# Create .env file with tokens (DO NOT commit this)
cat > .env << 'EOF'
GITHUB_TOKEN=ghp_your_token_here
DOCKERHUB_USERNAME=gavinmcnair
DOCKERHUB_TOKEN=your_dockerhub_token
EOF

docker compose -f docker-compose.arm64.yml up -d
```

### Step 4: Verify Runners

1. Go to https://github.com/gavinmcnair/gstreamer/settings/actions/runners
2. Both runners should show as **Idle** with their labels
3. If a runner shows "Offline", check container logs: `docker logs github-runner-arm64`

### Step 5: Multi-Repo Support

To use the same runners for multiple repos (gstreamer, tvproxy, gstreamer-plugin),
change the scope from repo-level to org-level:

```yaml
environment:
  - RUNNER_SCOPE=org
  - ORG_NAME=gavinmcnair    # or create a GitHub org
```

Or register multiple runners per container by changing `REPO_URL` — but the simplest
approach is one runner registered at the org level that all repos can use.

Alternatively, register each runner to each repo separately by repeating Step 2/3
with different `REPO_URL` values. The runner image supports this via the `EPHEMERAL`
mode or you can run multiple containers.

## Phase 2: Test Workflow (this repo)

This repo (`gavinmcnair/ci`) gets a trivial Dockerfile and a workflow that proves
the full multi-arch build+push+manifest pipeline works before we touch gstreamer.

### Test Dockerfile

```dockerfile
# Dockerfile — trivial image that prints architecture
FROM debian:bookworm-slim
RUN uname -m > /arch.txt
CMD cat /arch.txt && echo "CI runner works"
```

### Test Workflow

```yaml
# .github/workflows/test-build.yml
name: Test Multi-Arch Build

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  IMAGE: gavinmcnair/ci-test
  TAG: test

jobs:
  build-amd64:
    runs-on: [self-hosted, linux, amd64]
    steps:
      - uses: actions/checkout@v4
      - name: Log in to Docker Hub
        run: echo "${{ secrets.DOCKERHUB_TOKEN }}" | docker login -u "${{ secrets.DOCKERHUB_USERNAME }}" --password-stdin
      - name: Build
        run: docker build -t ${{ env.IMAGE }}:${{ env.TAG }}-amd64 .
      - name: Verify architecture
        run: docker run --rm ${{ env.IMAGE }}:${{ env.TAG }}-amd64 | grep -q x86_64
      - name: Push
        run: docker push ${{ env.IMAGE }}:${{ env.TAG }}-amd64

  build-arm64:
    runs-on: [self-hosted, linux, arm64]
    steps:
      - uses: actions/checkout@v4
      - name: Log in to Docker Hub
        run: echo "${{ secrets.DOCKERHUB_TOKEN }}" | docker login -u "${{ secrets.DOCKERHUB_USERNAME }}" --password-stdin
      - name: Build
        run: docker build -t ${{ env.IMAGE }}:${{ env.TAG }}-arm64 .
      - name: Verify architecture
        run: docker run --rm ${{ env.IMAGE }}:${{ env.TAG }}-arm64 | grep -q aarch64
      - name: Push
        run: docker push ${{ env.IMAGE }}:${{ env.TAG }}-arm64

  manifest:
    needs: [build-amd64, build-arm64]
    runs-on: [self-hosted, linux, arm64]
    steps:
      - name: Log in to Docker Hub
        run: echo "${{ secrets.DOCKERHUB_TOKEN }}" | docker login -u "${{ secrets.DOCKERHUB_USERNAME }}" --password-stdin
      - name: Create multi-arch manifest
        run: |
          docker manifest create ${{ env.IMAGE }}:${{ env.TAG }} \
            --amend ${{ env.IMAGE }}:${{ env.TAG }}-amd64 \
            --amend ${{ env.IMAGE }}:${{ env.TAG }}-arm64
          docker manifest push ${{ env.IMAGE }}:${{ env.TAG }}

  verify:
    needs: [manifest]
    strategy:
      matrix:
        runner: [[self-hosted, linux, amd64], [self-hosted, linux, arm64]]
    runs-on: ${{ matrix.runner }}
    steps:
      - name: Pull multi-arch image and verify
        run: |
          docker pull ${{ env.IMAGE }}:${{ env.TAG }}
          docker run --rm ${{ env.IMAGE }}:${{ env.TAG }}
```

### Success Criteria

- [ ] amd64 job runs on TrueNAS runner, prints x86_64
- [ ] arm64 job runs on Mac Studio runner, prints aarch64
- [ ] Manifest created and pushed to Docker Hub
- [ ] Verify job pulls the manifest image on BOTH runners and gets the correct native arch
- [ ] No QEMU emulation involved anywhere

### GitHub Secrets Required

Add these in repo Settings → Secrets and variables → Actions:
- `DOCKERHUB_USERNAME`: gavinmcnair
- `DOCKERHUB_TOKEN`: Docker Hub access token

## Phase 3: Adopt in gstreamer

Once Phase 2 passes, copy the workflow pattern to `gavinmcnair/gstreamer` with:
- The real Dockerfile (GStreamer from source + Rust plugins + tvproxy plugins)
- `make test` in the verify step
- Tag as `gavinmcnair/gstreamer:1.3` + `:latest`

The workflow is identical in structure — just a bigger Dockerfile and real tests.

## Runner Image: myoung34/docker-github-actions-runner

This is the most widely used community Docker image for self-hosted runners.
It handles:
- Auto-registration with GitHub on startup
- Auto-deregistration on shutdown
- Docker-in-Docker via socket mount
- Automatic updates to the runner binary
- Ephemeral mode (fresh runner per job) if desired

Source: https://github.com/myoung34/docker-github-actions-runner

Alternative: GitHub's official runner image `ghcr.io/actions/actions-runner` —
more minimal but requires more manual setup.

## Security Notes

- The Docker socket mount gives the runner container full Docker access on the host.
  This is required for building images but means a malicious workflow could access
  other containers. Acceptable for private repos with trusted committers.
- Use fine-grained PATs scoped to specific repos, not classic tokens with broad access.
- Don't run self-hosted runners on public repos — anyone can submit a PR that executes
  arbitrary code on your machine.
- The `.env` file with tokens must NOT be committed to git. Add it to `.gitignore`.

## Expected Build Times (Native)

| Stage | amd64 (Xeon 64-core) | arm64 (M3 Max) |
|-------|---------------------|----------------|
| GStreamer from source | ~5 min | ~8 min |
| Rust plugins (dav1d, isobmff, hlssink3, webrtc) | ~5 min | ~8 min |
| tvproxy plugins | <30 sec | <30 sec |
| Total | ~10 min | ~16 min |
| Both architectures in parallel | ~16 min | |

Compare to current QEMU cross-build: 45-60+ minutes for a single architecture.

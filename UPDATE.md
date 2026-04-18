# CI Infrastructure Update

## What was built

A multi-arch Docker build pipeline using self-hosted GitHub Actions runners. Validated end-to-end in the `gavinmcnair/ci` repo on 2026-04-18.

## Runners

Two self-hosted runners, one per architecture, building natively (no QEMU):

| Runner | Host | Architecture | Status |
|--------|------|-------------|--------|
| amd64 | TrueNAS (Xeon 64-core, 192GB) | linux/amd64 | Online |
| arm64 | Mac Studio (M3 Max, 64GB) | linux/arm64 | Online |

**Runner image:** `myoung34/github-runner:2.333.1`

Runners are currently registered **per-repo** (not org-level). To use them from tvproxy, each runner must be re-registered with `REPO_URL=https://github.com/gavinmcnair/tvproxy`, or migrated to org-level once a GitHub organization is created.

## How Docker Hub auth works

There are **no GitHub Actions secrets**. Docker Hub credentials are configured as environment variables on the runner containers themselves (`DOCKERHUB_LOGIN`, `DOCKERHUB_PASSWORD`). Workflows access them via the runner's environment:

```yaml
- name: Log in to Docker Hub
  run: echo "${DOCKERHUB_PASSWORD}" | docker login -u "${DOCKERHUB_LOGIN}" --password-stdin
```

This means:
- No secrets to configure in repo settings
- Credentials are managed on the runner hosts, not in GitHub
- Any repo using these runners gets Docker Hub push access automatically

## Workflow pattern for tvproxy

The proven workflow structure has four stages. Adapt `IMAGE` and `TAG` for tvproxy, replace the Dockerfile with the real one, and add `make test` to the verify step.

```yaml
name: Multi-Arch Build

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  IMAGE: gavinmcnair/tvproxy
  TAG: latest

jobs:
  build-amd64:
    runs-on: [self-hosted, linux, amd64]
    steps:
      - uses: actions/checkout@v4
      - name: Log in to Docker Hub
        run: echo "${DOCKERHUB_PASSWORD}" | docker login -u "${DOCKERHUB_LOGIN}" --password-stdin
      - name: Build
        run: docker build -t ${{ env.IMAGE }}:${{ env.TAG }}-amd64 .
      - name: Push
        run: docker push ${{ env.IMAGE }}:${{ env.TAG }}-amd64

  build-arm64:
    runs-on: [self-hosted, linux, arm64]
    steps:
      - uses: actions/checkout@v4
      - name: Log in to Docker Hub
        run: echo "${DOCKERHUB_PASSWORD}" | docker login -u "${DOCKERHUB_LOGIN}" --password-stdin
      - name: Build
        run: docker build -t ${{ env.IMAGE }}:${{ env.TAG }}-arm64 .
      - name: Push
        run: docker push ${{ env.IMAGE }}:${{ env.TAG }}-arm64

  manifest:
    needs: [build-amd64, build-arm64]
    runs-on: [self-hosted, linux, arm64]
    steps:
      - name: Log in to Docker Hub
        run: echo "${DOCKERHUB_PASSWORD}" | docker login -u "${DOCKERHUB_LOGIN}" --password-stdin
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
      - name: Pull and test
        run: |
          docker pull ${{ env.IMAGE }}:${{ env.TAG }}
          docker run --rm ${{ env.IMAGE }}:${{ env.TAG }} make test
```

## What tvproxy needs to do

1. **Register runners** — either re-register both runners with `REPO_URL=https://github.com/gavinmcnair/tvproxy`, or create a GitHub org and switch to org-level runners (preferred long-term)
2. **Add the workflow** — copy `.github/workflows/test-build.yml` adapted as above
3. **No secrets setup needed** — Docker Hub auth comes from the runner environment

## Runner setup reference (TrueNAS app)

For adding runners to new repos before org migration:

| Setting | Value |
|---------|-------|
| **Image** | `myoung34/github-runner` |
| **Tag** | `2.333.1` |
| **RUNNER_NAME** | `amd64` |
| **RUNNER_SCOPE** | `repo` |
| **REPO_URL** | `https://github.com/gavinmcnair/<repo>` |
| **LABELS** | `self-hosted,linux,amd64` |
| **ACCESS_TOKEN** | GitHub fine-grained PAT (Administration: Read and write, scoped to target repos) |
| **RUNNER_WORKDIR** | `/tmp/runner` |
| **DOCKER_ENABLED** | `true` |
| **DOCKERHUB_LOGIN** | Docker Hub username |
| **DOCKERHUB_PASSWORD** | Docker Hub access token (Read & Write) |
| **Volume mount** | `/var/run/docker.sock` -> `/var/run/docker.sock` |

## Validated results

All stages passed on 2026-04-18:

- amd64 build: 26s (native on TrueNAS)
- arm64 build: 18s (native on Mac Studio)
- Manifest creation: 10s
- Verify on both architectures: ~6s each
- Total wall time: ~1 minute for a trivial image

Compare to QEMU cross-build: 45-60+ minutes per architecture.

# GHCR Docker Publish Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds `xmpp-proxy-stack/Dockerfile.distroless` and publishes it to `ghcr.io/nikescar/xmpp-proxy-stack`, only after the existing bats unit + integration test suite passes.

**Architecture:** Single new workflow file, `.github/workflows/docker-publish.yml`, with two jobs: `test` (runs `bats tests/unit/` and `bats tests/integration/` from `xmpp-proxy-stack/`) and `publish` (`needs: test`; logs into GHCR, computes tags via `docker/metadata-action`, builds/pushes via `docker/build-push-action`). Triggers: pushing a `v*` tag, or manual `workflow_dispatch`. No branch-push trigger.

**Tech Stack:** GitHub Actions, `docker/login-action@v3`, `docker/metadata-action@v5`, `docker/setup-buildx-action@v3`, `docker/build-push-action@v6`, bats (via `apt-get install bats`).

## Global Constraints

- Only build/publish `xmpp-proxy-stack/Dockerfile.distroless` (not the legacy `Dockerfile`) — it's the one with bats coverage.
- `platforms: linux/amd64` only — `Dockerfile.distroless` hardcodes `x86_64-linux-gnu` lib paths, so arm64 is not supported yet. This is a known, called-out limitation, not a bug to fix here.
- No branch-push trigger — only `push: tags: ['v*']` and `workflow_dispatch`.
- `publish` job must not run unless `test` job succeeds (`needs: test`).
- `latest` tag must only ever be applied to a real `v*` tag build, never to a manual `workflow_dispatch` run off a branch.
- Use the built-in `GITHUB_TOKEN` for GHCR auth — no new secret.
- Do not actually trigger a real push to `ghcr.io` from this local environment — the user said they will test that manually (by pushing a tag or running the workflow from the Actions UI). Verification here is limited to: running the exact same bats commands locally, and running `actionlint` against the finished file.

---

### Task 1: `test` job — bats unit + integration gate

**Files:**
- Create: `.github/workflows/docker-publish.yml`

**Interfaces:**
- Produces: a `test` job (name `test`) in `.github/workflows/docker-publish.yml` that later tasks reference via `needs: test`.

- [ ] **Step 1: Create the workflow file with only the `test` job**

```yaml
name: Build and Publish Docker Image

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  test:
    name: Run bats test suite
    runs-on: ubuntu-latest
    steps:
      - name: Check out the repo
        uses: actions/checkout@v4

      - name: Install bats
        run: sudo apt-get update && sudo apt-get install -y bats

      - name: Run unit tests
        working-directory: xmpp-proxy-stack
        run: bats tests/unit/

      - name: Run integration tests
        working-directory: xmpp-proxy-stack
        run: bats tests/integration/

      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: bats-integration-logs
          path: |
            /tmp/xmpp-test-logs.txt
            /tmp/xmpp-test-e2e-logs.txt
          if-no-files-found: ignore
```

- [ ] **Step 2: Validate the YAML/Actions syntax**

Run: `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest .github/workflows/docker-publish.yml`
Expected: no output (actionlint prints nothing and exits 0 when there are no findings).

- [ ] **Step 3: Install bats locally and run the exact same test commands the workflow runs**

```bash
sudo apt-get update && sudo apt-get install -y bats
cd xmpp-proxy-stack
bats tests/unit/
bats tests/integration/
```

Expected: all unit tests pass; all integration tests pass (`test_distroless_build.bats`, `test_service_startup.bats`, `test_proxy_e2e.bats`). This proves the exact commands the workflow will run actually succeed in a fresh environment, not just that the YAML parses. If any test fails, stop and fix the underlying bats test/Dockerfile bug before proceeding — do not weaken the workflow to work around a real failure.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/docker-publish.yml
git commit -m "ci: add bats test gate for xmpp-proxy-stack docker image"
```

---

### Task 2: `publish` job — build and push to GHCR

**Files:**
- Modify: `.github/workflows/docker-publish.yml` (append the `publish` job after `test`)

**Interfaces:**
- Consumes: the `test` job produced in Task 1 (referenced via `needs: test`).
- Produces: a `publish` job that builds `xmpp-proxy-stack/Dockerfile.distroless` and pushes to `ghcr.io/nikescar/xmpp-proxy-stack`.

- [ ] **Step 1: Append the `publish` job**

Add this job to the `jobs:` section of `.github/workflows/docker-publish.yml`, after `test`:

```yaml
  publish:
    name: Build and push image to GHCR
    needs: test
    runs-on: ubuntu-latest
    steps:
      - name: Check out the repo
        uses: actions/checkout@v4

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute image tags
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/nikescar/xmpp-proxy-stack
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,format=short,prefix=sha-
            type=ref,event=branch

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: xmpp-proxy-stack
          file: xmpp-proxy-stack/Dockerfile.distroless
          # Dockerfile.distroless hardcodes x86_64-linux-gnu lib paths (see
          # its own comments), so it can only be built for amd64 today.
          platforms: linux/amd64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Validate the full workflow's syntax**

Run: `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest .github/workflows/docker-publish.yml`
Expected: no output.

- [ ] **Step 3: Trace the tag logic by hand for both trigger cases**

Confirm (by reading the `tags:` block against `docker/metadata-action`'s documented behavior) that:
- A push of tag `v1.2.3` produces: `1.2.3`, `1.2`, `sha-<short-sha>`, and (via metadata-action's default `latest=auto` flavor for `type=semver`) `latest`.
- A `workflow_dispatch` run against branch `feature/dure-docker` produces: `sha-<short-sha>` and `feature-dure-docker` (branch name sanitized by metadata-action), and **no** `latest` tag, since `type=semver` does not match a non-tag ref.

Do not run this against the real registry — this is a manual read-through check only, per the global constraints.

- [ ] **Step 4: Confirm the build context builds locally (build-only, no push)**

```bash
docker buildx build --platform linux/amd64 -f xmpp-proxy-stack/Dockerfile.distroless xmpp-proxy-stack -t xmpp-proxy-stack:ghcr-dry-run
```

Expected: build succeeds (this exercises the same context/file/platform the `publish` job will use, without touching `ghcr.io`). Clean up afterwards:

```bash
docker rmi xmpp-proxy-stack:ghcr-dry-run
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/docker-publish.yml
git commit -m "ci: publish xmpp-proxy-stack image to ghcr.io after tests pass"
```

---

## Manual Verification (user, post-merge)

Not part of either task's automated steps — call these out to the user once the plan is executed:
1. Push a `v*` tag (or use "Run workflow" in the Actions UI) and confirm the `publish` job runs after `test` succeeds.
2. Confirm the image appears at `ghcr.io/nikescar/xmpp-proxy-stack` with the expected tags.
3. Confirm the package visibility setting in GitHub (new GHCR packages default to private) matches what's wanted.

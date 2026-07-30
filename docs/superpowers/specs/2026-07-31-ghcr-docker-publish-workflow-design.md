# GHCR Docker Publish Workflow Design

## Purpose

Add a GitHub Actions workflow that builds the `xmpp-proxy-stack` Docker image
and publishes it to `ghcr.io/nikescar/xmpp-proxy-stack`, but only after the
existing bats test suite proves the image actually boots and serves traffic.
Today the image is only ever built locally via `docker compose build`; there
is no automated build or publish path.

## Scope

One new workflow file: `.github/workflows/docker-publish.yml`. No changes to
the existing `release.yml` (binary releases) or to the Dockerfiles/tests
themselves, except where a real bug is found while wiring CI up (handled as
a normal bugfix commit, not part of this spec).

## Triggers

```yaml
on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
```

No branch-push trigger. The workflow only runs when a version tag is pushed,
or when someone manually runs it via `workflow_dispatch` (e.g. to rebuild an
image after an unrelated infra change, or to sanity-check the pipeline on a
feature branch before tagging a release).

## Job 1: `test`

Runs unconditionally on every trigger. This is the gate — job 2 cannot start
if this fails.

1. `actions/checkout@v4`
2. Install `bats` (`sudo apt-get install -y bats`)
3. `bats tests/unit/` (run from `xmpp-proxy-stack/`) — pure bash-logic tests
   against `nginx-proxy-ctl`, no Docker required, fast fail for basic
   regressions.
4. `bats tests/integration/` (run from `xmpp-proxy-stack/`) — this is the
   "does the service actually work" gate:
   - `test_distroless_build.bats`: builds `Dockerfile.distroless`, checks the
     image has no shell, and that all expected binaries/configs/dirs exist.
   - `test_service_startup.bats`: brings the container up via
     `docker-compose -f tests/docker-compose.test.yml`, verifies it reaches
     "Initialization complete", generates a self-signed cert fallback, and
     that nginx is running and logging.
   - `test_proxy_e2e.bats`: runs the built image plus a `http-echo` backend,
     exercises `nginx-proxy-ctl add/list/remove/validate` through real HTTP
     requests against the running proxy.
   - These tests already require Docker and `--cap-add NET_ADMIN`, both
     available on GitHub-hosted `ubuntu-latest` runners without extra setup.
5. On failure: upload `/tmp/xmpp-test-logs.txt` and
   `/tmp/xmpp-test-e2e-logs.txt` (written by each suite's `teardown_file`) as
   a build artifact, so a failing run is debuggable from the Actions UI
   without needing to reproduce locally.

## Job 2: `publish`

`needs: test`. Runs on both remaining trigger types (tag push and
`workflow_dispatch`) — there is no "only push on branch X" special case
anymore since the branch-push trigger was removed.

1. `docker/login-action@v3` against `ghcr.io`, using the built-in
   `GITHUB_TOKEN` (needs `packages: write` permission set on the workflow;
   no new secret required).
2. `docker/metadata-action@v5` computes tags for
   `ghcr.io/nikescar/xmpp-proxy-stack`:
   - On a `v*` tag push: semver tags (`1.2.3`, `1.2`) **and** `latest` — so
     `latest` only ever tracks an actual tagged release, never an
     in-between manual build.
   - On `workflow_dispatch`: a `sha-<short-sha>` tag and a sanitized
     branch-name tag (e.g. `feature-dure-docker`) — visible, disposable,
     and never touches `latest`.
3. `docker/build-push-action@v6`:
   - `context: xmpp-proxy-stack`
   - `file: xmpp-proxy-stack/Dockerfile.distroless`
   - `platforms: linux/amd64` — the distroless image hardcodes
     `x86_64-linux-gnu` lib paths today (see comments in the Dockerfile), so
     it cannot be built for arm64 yet. This is a known, called-out
     limitation, not silently swept under the rug.
   - `push: true`
   - `cache-from`/`cache-to: type=gha` for faster rebuilds across runs.
   - `tags`/`labels` from the metadata-action output.

## Failure Handling

- Any bats failure in job 1 stops the pipeline before anything is pushed —
  this is the core requirement ("test container before publish").
- A build/push failure in job 2 fails the workflow normally; no partial or
  incorrectly-tagged image is left on GHCR because `build-push-action` only
  pushes after a fully successful build.

## Out of Scope

- Multi-arch (arm64) publishing — blocked on the Dockerfile's hardcoded
  amd64 lib paths, a separate pre-existing issue.
- Publishing the legacy `Dockerfile` (debian-slim) — it has no bats
  coverage today, so it can't satisfy the "test before publish" gate this
  workflow exists to provide.
- Changes to `release.yml` (binary releases) — unrelated pipeline.

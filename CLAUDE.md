# CLAUDE.md

## Project Overview

A minimal, actively-rebuilt Docker image (`ghcr.io/drumandbytes/nordvpn`) wrapping the official NordVPN Linux client on distroless, since the community alternatives are years stale. Three-stage `Dockerfile`: install the real `.deb` + OS deps on `debian:trixie-slim`, compile a small Go `entrypoint` (`main.go`) to replace the old shell entrypoint/healthcheck (distroless has no shell), copy only the needed binaries/libs onto `gcr.io/distroless/base-debian13`. See [README.md](README.md) for usage/env vars and the Dockerfile's own comments for the exact file-list/multiarch rationale (hard-won: things like `nft`, `sysctl`, `ps` were added only after a specific code path broke at runtime).

## Quick Start

```bash
go build -o entrypoint .
go vet ./...
docker build -t nordvpn .
```

CI (`validate.yml`) runs `drumandbytes/reusable-actions` go-ci + a Trivy scan + a smoke test that boots the built image with no config and checks it doesn't crash.

## `upstream.lock` — read this before touching it

The Dockerfile pins almost nothing on purpose — `nordvpn`, `iptables`, `iproute2`, `wireguard-tools`, `nftables` install unpinned from their apt channels so the image always ships whatever's currently in NordVPN's `stable` channel and current Debian trixie. That's correct for a VPN client but means the same Dockerfile builds a different image week to week with no commit to hang a version off.

`upstream.lock` is **not a build pin** — nothing reads it at build time. It's a fingerprint of every upstream input that can change the image (nordvpn client version, apt package versions from both trixie and trixie-security, and base image digests for `debian:trixie-slim`/`golang:1.27-trixie`/`distroless/base-debian13`), used purely for *drift detection*.

- `scripts/upstream-lock.sh` recomputes the fingerprint from live sources.
- `.github/workflows/upstream-check.yml` runs it daily, diffs against the committed `upstream.lock`, and if anything moved, opens a PR (as `dnb-robot[bot]`) updating `upstream.lock` and `.nordvpn-version`.
- Merging that PR is what triggers a release: release-please cuts a patch, `build.yml` publishes a new semver image tag.

**Don't hand-edit `upstream.lock`.** It should only ever change via that automated PR. If you need to force a re-check, run `./scripts/upstream-lock.sh` locally and compare, or trigger the `Upstream check` workflow manually (`workflow_dispatch`); don't just bump values by hand.

## Conventions

- Commits: Conventional Commits (`fix(deps):`, `feat:`, `chore(ci):`) — release-please reads them for versioning/`CHANGELOG.md`. No `Co-Authored-By` trailers.
- `main` stays releasable; release-please and upstream-check PRs auto-merge via `drumandbytes/reusable-actions`.
- Every published image carries a signed SLSA provenance attestation (see README's "Verifying the image").

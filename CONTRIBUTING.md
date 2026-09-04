# Contributing

## Commits and releases

Releases are automated with [release-please](https://github.com/googleapis/release-please).
It reads the commit history on `main`, keeps a rolling **release PR** with the next
version + `CHANGELOG.md`, and on merge tags `vX.Y.Z` + creates the GitHub Release.
`build.yml` then publishes `ghcr.io/drumandbytes/nordvpn:X.Y.Z` and `:X.Y` (immutable).

Image tags:

| Tag | Source | Meaning |
| --- | --- | --- |
| `:latest`, `:YYYYMMDD` | `main` pushes + the weekly cron | rolling — this repo's `main` + whatever the NordVPN apt repo had at build time |
| `:X.Y.Z`, `:X.Y` | release-please tags | pinned — frozen to that release's source + apt state |

**Squash-merge every PR** with a
[Conventional Commits](https://www.conventionalcommits.org/) title:

| Prefix | Effect | Example |
| --- | --- | --- |
| `feat:` | minor bump | `feat: expose the NordVPN meshnet toggle` |
| `fix:` / `perf:` | patch bump | `fix: wait for the daemon socket before connecting` |
| `feat!:` or `BREAKING CHANGE:` in body | major bump | `feat!: drop the legacy env-var config` |
| `chore:` `docs:` `ci:` `test:` `refactor:` | no release | `docs: update the README` |

Dependabot prefixes Go and base-image bumps `fix(deps):` (→ patch release + new
pinned image) and action bumps `ci(deps):` (CI only, no release).

`nordvpn-version.yml` polls NordVPN's apt channel daily; a new client version
opens a `fix(nordvpn):` PR bumping `.nordvpn-version` → patch release. That file
is the record of which client each `vX.Y.Z` shipped (the Dockerfile itself still
installs whatever's current at build time). The weekly `build.yml` cron keeps the
rolling `:latest` / `:YYYYMMDD` tags fresh with Debian security patches.

Don't hand-edit `CHANGELOG.md` or tags — release-please owns them.

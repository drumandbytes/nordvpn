#!/usr/bin/env bash
# Every nordvpn CLI verb the entrypoint or README relies on must still exist.
# A client release that drops one (6.0 removed `set technology`) otherwise only
# shows up as a runtime warning. Needs no login: --help runs without the daemon.
#
# usage: cli-check.sh <image>

set -euo pipefail

IMAGE="${1:?usage: cli-check.sh <image>}"
VERBS=(
  "login"
  "connect"
  "set analytics"
  "set firewall"
  "set killswitch"
  "set meshnet"
  "set protocol"
  "set post-quantum"
  "set arp-ignore"
  "allowlist add subnet"
  "allowlist add port"
  "allowlist remove"
  "meshnet set nickname"
  "meshnet peer list"
)

missing=0
for verb in "${VERBS[@]}"; do
  # word-split on purpose: "set analytics" is two CLI args. Captured first:
  # `grep -q` closing the pipe early would SIGPIPE docker and trip pipefail.
  # shellcheck disable=SC2086
  out=$(docker run --rm --entrypoint /usr/bin/nordvpn "$IMAGE" $verb --help 2>&1 || true)
  if ! grep -q '^Usage:' <<< "$out"; then
    echo "::error::nordvpn ${verb} no longer exists"
    missing=1
  fi
done
exit "$missing"

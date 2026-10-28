#!/usr/bin/env bash
# End-to-end check against NordVPN's real service: login, connect over each
# protocol, Meshnet. The smoke test only proves the container boots, so
# anything that breaks on connect (removed CLI verbs, missing helper
# binaries, sysctl writes) only shows up here.
#
# Needs NORDVPN_TOKEN in the environment; usage: live-test.sh <image>.
# Run one case at a time: they share one account's 10-device limit.

set -euo pipefail

IMAGE="${1:?usage: live-test.sh <image>}"
: "${NORDVPN_TOKEN:?NORDVPN_TOKEN not set}"
NAME="nordvpn-live-$$"
# Presets for the writes nordvpnd makes on connect (see README, "Container sysctls").
SYSCTLS=(--sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv4.conf.all.arp_ignore=1)

cleanup() {
  # logout (no --revoke-token) drops the device but keeps the token usable
  docker exec "$NAME" /usr/bin/nordvpn logout >/dev/null 2>&1 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

nordvpn() { docker exec "$NAME" /usr/bin/nordvpn "$@"; }

# A device can't remove itself from Meshnet, and logout leaves it registered
# (the account has a 10-device limit). Another device can: each run removes the
# ci-* devices earlier runs left behind, so at most one stays.
purge_stale_meshnet() {
  local own="$1" nick
  while read -r nick; do
    [ "$nick" = "$own" ] || nordvpn meshnet peer remove "$nick" || true
  done < <(nordvpn meshnet peer list | awk '/^Nickname: ci-/{print $2}')
}

# run <label> <expected status regex> <docker run -e args...>
run_case() {
  local label="$1" want="$2"
  shift 2
  echo "::group::${label}"
  docker run -d --name "$NAME" --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --device=/dev/net/tun "${SYSCTLS[@]}" -e NORDVPN_TOKEN \
    -e NORDVPN_FIREWALL=off "$@" "$IMAGE" >/dev/null

  local ok=""
  for _ in $(seq 60); do
    if docker exec "$NAME" /entrypoint healthcheck; then ok=1; break; fi
    sleep 3
  done

  # captured first: `grep -q` closing the pipe early would trip pipefail
  local state
  state=$({ nordvpn status; nordvpn settings; } 2>/dev/null || true)
  if [ -z "$ok" ] || ! grep -Eq "$want" <<< "$state"; then
    echo "::error::${label} failed"
    docker logs "$NAME" 2>&1 | grep -E '^warning|\[Error\]' | cut -c1-300 | tail -20
    nordvpn account >/dev/null 2>&1 || echo "::error::login failed: NORDVPN_TOKEN invalid or expired?"
    echo "::endgroup::"
    exit 1
  fi
  [ "$label" != meshnet ] || purge_stale_meshnet "ci-${GITHUB_RUN_ID:-local}"
  echo "ok"
  echo "::endgroup::"
  cleanup
}

run_case "nordlynx" "Protocol: NordLynx" -e NORDVPN_CONNECT=Netherlands
run_case "openvpn_udp" "Protocol: OpenVPN \(UDP\)" \
  -e NORDVPN_SET="protocol openvpn_udp" -e NORDVPN_CONNECT=Netherlands
run_case "openvpn_tcp" "Protocol: OpenVPN \(TCP\)" \
  -e NORDVPN_SET="protocol openvpn_tcp" -e NORDVPN_CONNECT=Germany
run_case "meshnet" "Meshnet: enabled" \
  -e NORDVPN_MESHNET=on -e NORDVPN_NICKNAME="ci-${GITHUB_RUN_ID:-local}"

#!/bin/sh
set -e

# No systemd inside the container, so run the daemon directly and talk to it
# over its usual control socket via the nordvpn CLI, same approach NordVPN's
# own "build the Docker image" support article uses.
/usr/sbin/nordvpnd &
NORDVPND_PID=$!

# shellcheck disable=SC2034 # loop counter, intentionally unused
for i in $(seq 1 30); do
  nordvpn status >/dev/null 2>&1 && break
  sleep 1
done

if [ -n "$NORDVPN_TOKEN" ]; then
  nordvpn login --token "$NORDVPN_TOKEN" || echo "warning: login failed — fix interactively with exec, nordvpnd keeps running" >&2
fi

# Everything below is opt-in — this image is a plain NordVPN client, usable
# for a regular VPN tunnel, Meshnet, or both at once. Nothing is assumed.
#
# Each is allowed to fail without taking the container down with it: e.g.
# NORDVPN_CONNECT set without NORDVPN_TOKEN (or before you've exec'd in to
# log in manually) would otherwise kill nordvpnd along with the whole
# container on the very first failed command, well before there's any
# chance to fix it interactively.

if [ -n "$NORDVPN_FIREWALL" ]; then
  nordvpn set firewall "$NORDVPN_FIREWALL" || echo "warning: setting firewall failed" >&2
fi

if [ -n "${NORDVPN_CONNECT+set}" ]; then
  # Bare `nordvpn connect` (empty value) picks the recommended server.
  # A value can be a country, city, server, or group — anything the CLI's
  # own `connect` argument accepts — and a two-word value like
  # "Hungary Budapest" needs to reach the CLI as two separate arguments,
  # so this word-split is intentional, not a missed quoting bug.
  # shellcheck disable=SC2086
  nordvpn connect ${NORDVPN_CONNECT} || echo "warning: connect failed (not logged in yet?) — fix interactively with exec" >&2
fi

if [ "$NORDVPN_MESHNET" = "on" ]; then
  nordvpn set meshnet on || echo "warning: enabling meshnet failed" >&2
  if [ -n "$NORDVPN_NICKNAME" ]; then
    nordvpn meshnet set nickname "$NORDVPN_NICKNAME" || echo "warning: setting nickname failed" >&2
  fi
fi

wait "$NORDVPND_PID"

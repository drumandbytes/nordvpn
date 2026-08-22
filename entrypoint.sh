#!/bin/sh
set -e

# No systemd inside the container, so run the daemon directly and talk to it
# over its usual control socket via the nordvpn CLI, same approach NordVPN's
# own "build the Docker image" support article uses.
/usr/sbin/nordvpnd &
NORDVPND_PID=$!

for i in $(seq 1 30); do
  nordvpn status >/dev/null 2>&1 && break
  sleep 1
done

if [ -n "$NORDVPN_TOKEN" ]; then
  nordvpn login --token "$NORDVPN_TOKEN"
fi

# Everything below is opt-in — this image is a plain NordVPN client, usable
# for a regular VPN tunnel, Meshnet, or both at once. Nothing is assumed.

if [ -n "$NORDVPN_FIREWALL" ]; then
  nordvpn set firewall "$NORDVPN_FIREWALL"
fi

if [ -n "${NORDVPN_CONNECT+set}" ]; then
  # Bare `nordvpn connect` (empty value) picks the recommended server.
  # A value can be a country, city, server, or group — anything the CLI's
  # own `connect` argument accepts.
  nordvpn connect ${NORDVPN_CONNECT}
fi

if [ "$NORDVPN_MESHNET" = "on" ]; then
  nordvpn set meshnet on
  if [ -n "$NORDVPN_NICKNAME" ]; then
    nordvpn meshnet set nickname "$NORDVPN_NICKNAME"
  fi
fi

wait "$NORDVPND_PID"

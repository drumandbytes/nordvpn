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

nordvpn set meshnet on

if [ -n "$NORDVPN_NICKNAME" ]; then
  nordvpn meshnet set nickname "$NORDVPN_NICKNAME"
fi

# Off by default: we're not routing all pod egress through a NordVPN exit
# server (no `nordvpn connect`), so the killswitch would otherwise block the
# sidecar's normal LAN/internet traffic (metadata lookups, DNS). Cilium
# NetworkPolicy governs the pod's normal egress instead.
nordvpn set firewall "${NORDVPN_FIREWALL:-off}"

wait "$NORDVPND_PID"

#!/bin/sh
# Used as a Kubernetes exec livenessProbe. Passes if either a regular VPN
# tunnel is connected or Meshnet is enabled — adjust to just one condition if
# you're only using this image for one of the two. CLI output format is
# unversioned upstream, worth a sanity check against a real login.
nordvpn status | grep -qi "Status: Connected" \
  || nordvpn settings | grep -qi "Meshnet: enabled"

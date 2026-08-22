#!/bin/sh
# Used as a Kubernetes exec livenessProbe. `nordvpn settings` lists feature
# toggles including a "Meshnet: enabled/disabled" line — verify this grep
# still matches once running against a real login (CLI output format is
# unversioned upstream, worth a sanity check on first deploy).
nordvpn settings | grep -qi "Meshnet: enabled"

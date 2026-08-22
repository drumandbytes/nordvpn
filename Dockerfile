# Thin wrapper around the official NordVPN Linux client, built fresh each
# time from repo.nordvpn.com's apt repo — the community images we looked at
# (bubuntux/nordvpn, MattsTechInfo/Meshnet) are 2-4 years stale, and there's
# nothing to them beyond "install the official client and run nordvpnd
# without systemd", so we own it instead. Rebuilt weekly by
# .github/workflows/build.yml, always pulling whatever's current in the
# "stable" apt channel at build time. Works for a regular VPN tunnel,
# Meshnet, or both — see entrypoint.sh, nothing is enabled by default.
FROM debian:bookworm-slim

# hadolint ignore=DL3008
# Deliberately not pinning package versions — the entire point of this
# image is always installing whatever's current in NordVPN's "stable"
# channel at build time (weekly rebuilds), not a fixed version.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
    && curl -fsSL https://repo.nordvpn.com/gpg/nordvpn_public.asc -o /tmp/nordvpn.asc \
    && gpg --dearmor -o /usr/share/keyrings/nordvpn.gpg /tmp/nordvpn.asc \
    && rm /tmp/nordvpn.asc \
    && echo "deb [signed-by=/usr/share/keyrings/nordvpn.gpg] https://repo.nordvpn.com/deb/nordvpn/debian stable main" \
       > /etc/apt/sources.list.d/nordvpn.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nordvpn iptables iproute2 wireguard-tools \
    && apt-get purge -y curl gnupg \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]

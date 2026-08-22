# Three-stage build. Full rationale: install the real .deb (and its OS
# dependencies) on Debian as normal, compile a small Go binary to replace
# the shell entrypoint (distroless has no shell at all), then copy only
# the resulting binaries and shared libraries onto distroless/base-debian12
# for the actual runtime image — no apt, no shell, no package manager in
# what ships. The exact file list below came from inspecting the real
# package (`dpkg -L nordvpn`) and each binary's real dependency graph
# (`ldd`) directly, not guessed.
#
# Deliberately not pinning the nordvpn/iptables/iproute2/wireguard-tools
# package versions in deb-builder — the entire point of this image is
# always installing whatever's current in NordVPN's "stable" channel at
# build time (weekly rebuilds), not a fixed version.

FROM debian:bookworm-slim AS deb-builder
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
    && curl -fsSL https://repo.nordvpn.com/gpg/nordvpn_public.asc -o /tmp/nordvpn.asc \
    && gpg --dearmor -o /usr/share/keyrings/nordvpn.gpg /tmp/nordvpn.asc \
    && rm /tmp/nordvpn.asc \
    && echo "deb [signed-by=/usr/share/keyrings/nordvpn.gpg] https://repo.nordvpn.com/deb/nordvpn/debian stable main" \
       > /etc/apt/sources.list.d/nordvpn.list \
    && apt-get update \
    # hadolint ignore=DL3008
    && apt-get install -y --no-install-recommends nordvpn iptables iproute2 wireguard-tools

FROM golang:1.23-bookworm AS go-builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /entrypoint .

FROM gcr.io/distroless/base-debian12:latest

# The nordvpn CLI + daemon, its own bundled libraries, and its helper
# binaries (nordfileshare, norduserd, openvpn) — the whole
# /usr/lib/nordvpn tree, since several of these dynamically load each
# other (nordfileshare needs libmoosenordvpnapp.so + libnorddrop.so, etc).
COPY --from=deb-builder /usr/bin/nordvpn /usr/bin/nordvpn
COPY --from=deb-builder /usr/sbin/nordvpnd /usr/sbin/nordvpnd
COPY --from=deb-builder /usr/lib/nordvpn/ /usr/lib/nordvpn/
COPY --from=deb-builder /var/lib/nordvpn/data/ /var/lib/nordvpn/data/

# iptables, ip, wg — the actual networking tools nordvpnd shells out to.
COPY --from=deb-builder /usr/sbin/iptables /usr/sbin/iptables
COPY --from=deb-builder /usr/sbin/ip /usr/sbin/ip
COPY --from=deb-builder /usr/bin/wg /usr/bin/wg

# Shared libraries distroless/base-debian12 doesn't already ship — every
# entry here came from `ldd` on the binaries above, cross-checked against
# what's already present in the base image. Same directory as glibc's own
# libs so the dynamic linker finds them without extra config.
COPY --from=deb-builder /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libsqlite3.so.0 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libxtables.so.12 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libmnl.so.0 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libnftnl.so.11 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libbpf.so.1 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libelf.so.1 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libbsd.so.0 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libcap.so.2 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libmd.so.0 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libnl-genl-3.so.200 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libnl-3.so.200 /lib/x86_64-linux-gnu/
COPY --from=deb-builder /lib/x86_64-linux-gnu/libcap-ng.so.0 /lib/x86_64-linux-gnu/

# nordvpn's own bundled libraries live outside the standard search path.
ENV LD_LIBRARY_PATH=/usr/lib/nordvpn

COPY --from=go-builder /entrypoint /entrypoint

ENTRYPOINT ["/entrypoint"]

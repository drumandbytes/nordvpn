# Three-stage build. Full rationale: install the real .deb (and its OS
# dependencies) on Debian as normal, compile a small Go binary to replace
# the shell entrypoint (distroless has no shell at all), then copy only
# the resulting binaries and shared libraries onto distroless/base-debian12
# for the actual runtime image — no apt, no shell, no package manager in
# what ships. The exact file list came from inspecting the real package
# (`dpkg -L nordvpn`) and each binary's real dependency graph (`ldd`)
# directly, not guessed.
#
# Deliberately not pinning the nordvpn/iptables/iproute2/wireguard-tools
# package versions in deb-builder — the entire point of this image is
# always installing whatever's current in NordVPN's "stable" channel at
# build time (weekly rebuilds), not a fixed version.

FROM debian:bookworm-slim AS deb-builder
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl gnupg ca-certificates \
    && curl -fsSL https://repo.nordvpn.com/gpg/nordvpn_public.asc -o /tmp/nordvpn.asc \
    && gpg --dearmor -o /usr/share/keyrings/nordvpn.gpg /tmp/nordvpn.asc \
    && rm /tmp/nordvpn.asc \
    && echo "deb [signed-by=/usr/share/keyrings/nordvpn.gpg] https://repo.nordvpn.com/deb/nordvpn/debian stable main" \
       > /etc/apt/sources.list.d/nordvpn.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nordvpn iptables iproute2 wireguard-tools

# Collect everything the final stage needs into one arch-neutral tree,
# mirroring its destination layout exactly. This has to happen here, not as
# hardcoded paths in the final stage's COPY instructions: the actual
# multiarch library directory (x86_64-linux-gnu vs aarch64-linux-gnu) is
# only known once buildx is actually building for a given --platform, so it
# has to be resolved here where `dpkg --print-architecture` (always
# available, no dpkg-dev needed) can tell us. (Shipped broken once already:
# every path was hardcoded to x86_64-linux-gnu, so the linux/arm64 leg of
# the multi-platform build failed outright — libcap-ng.so.0 "not found"
# because it was looking on the wrong architecture's path entirely, not
# because the file was genuinely missing.)
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) triplet=x86_64-linux-gnu ;; \
      arm64) triplet=aarch64-linux-gnu ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    mkdir -p /staging/usr/bin /staging/usr/sbin \
             /staging/usr/lib/nordvpn /staging/var/lib/nordvpn/data \
             "/staging/lib/${triplet}"; \
    cp /usr/bin/nordvpn /usr/bin/wg /staging/usr/bin/; \
    cp /usr/sbin/nordvpnd /usr/sbin/iptables /usr/sbin/ip /staging/usr/sbin/; \
    cp -r /usr/lib/nordvpn/. /staging/usr/lib/nordvpn/; \
    cp -r /var/lib/nordvpn/data/. /staging/var/lib/nordvpn/data/; \
    for lib in \
      libgcc_s.so.1 libsqlite3.so.0 libxtables.so.12 libmnl.so.0 \
      libnftnl.so.11 libbpf.so.1 libelf.so.1 libbsd.so.0 libcap.so.2 \
      libz.so.1 libmd.so.0 libnl-genl-3.so.200 libnl-3.so.200 libcap-ng.so.0; \
    do \
      cp "/lib/${triplet}/${lib}" "/staging/lib/${triplet}/"; \
    done

FROM golang:1.27-bookworm AS go-builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /entrypoint .

# Always installing whatever's current, same reasoning as the nordvpn
# package above — the weekly rebuild is what keeps this patched.
# hadolint ignore=DL3007
FROM gcr.io/distroless/base-debian12:latest

# Binaries, nordvpn's own bundled libraries, its data files, and every
# shared library ldd found that distroless doesn't already ship — already
# laid out at their exact final paths (including the correct
# architecture's multiarch lib directory) by the staging step above, so
# this is the only COPY the final stage needs.
COPY --from=deb-builder /staging/ /

# nordvpn's own bundled libraries live outside the standard search path.
ENV LD_LIBRARY_PATH=/usr/lib/nordvpn

COPY --from=go-builder /entrypoint /entrypoint

ENTRYPOINT ["/entrypoint"]

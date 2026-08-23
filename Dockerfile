# Three-stage build. Full rationale: install the real .deb (and its OS
# dependencies) on Debian as normal, compile a small Go binary to replace
# the shell entrypoint (distroless has no shell at all), then copy only
# the resulting binaries and shared libraries onto distroless/base-debian13
# for the actual runtime image — no apt, no shell, no package manager in
# what ships. The exact file list came from inspecting the real package
# (`dpkg -L nordvpn`) and each binary's real dependency graph (`ldd`)
# directly, not guessed — and re-verified against trixie specifically after
# moving off bookworm, since library versions/dependency sets genuinely
# differ between Debian releases (e.g. `ip` needs libselinux/libpcre2 on
# trixie but not libbsd/libmd like it did on bookworm — though libbsd/libmd
# came back anyway once nft was added, needed there for an unrelated
# reason). nft itself was missing entirely at first: nordvpnd shells out to
# it by bare name (PATH lookup) for firewall/routing setup during `connect`,
# invisible until an actual connect attempt was tried — `iptables` alone
# wasn't enough, it's a genuinely separate binary/package (nftables).
#
# Deliberately not pinning the nordvpn/iptables/iproute2/wireguard-tools
# package versions in deb-builder — the entire point of this image is
# always installing whatever's current in NordVPN's "stable" channel at
# build time (weekly rebuilds), not a fixed version.
#
# debian:trixie-slim / distroless/base-debian13 — trixie is current Debian
# stable (bookworm is oldstable now), so this tracks the same "always
# current" reasoning as everything else in this file.

FROM debian:trixie-slim AS deb-builder
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
    && apt-get install -y --no-install-recommends nordvpn iptables iproute2 wireguard-tools nftables

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
#
# Libraries stage into usr/lib/<triplet>, not lib/<triplet>: distroless's
# debian13 base has /lib as a symlink to usr/lib (Debian's usrmerge), and
# BuildKit's COPY refuses to merge a source tree through a symlinked
# destination component ("cannot copy to non-directory") — a real
# difference from the legacy `docker build` engine, which tolerates it
# fine. Shipped broken once already: verified locally with the legacy
# builder (no buildx available there), which hid this completely; only
# showed up once CI's actual BuildKit-based build ran it. usr/lib/<triplet>
# is the real, non-symlinked path on both bookworm and trixie, so this
# works on either regardless of which one distroless's usrmerge status
# happens to be for a given release.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) triplet=x86_64-linux-gnu ;; \
      arm64) triplet=aarch64-linux-gnu ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    mkdir -p /staging/usr/bin /staging/usr/sbin \
             /staging/usr/lib/nordvpn /staging/var/lib/nordvpn/data \
             "/staging/usr/lib/${triplet}"; \
    cp /usr/bin/nordvpn /usr/bin/wg /staging/usr/bin/; \
    cp /usr/sbin/nordvpnd /usr/sbin/iptables /usr/sbin/ip /usr/sbin/nft /staging/usr/sbin/; \
    cp -r /usr/lib/nordvpn/. /staging/usr/lib/nordvpn/; \
    cp -r /var/lib/nordvpn/data/. /staging/var/lib/nordvpn/data/; \
    for lib in \
      libgcc_s.so.1 libsqlite3.so.0 libxtables.so.12 libmnl.so.0 \
      libnftnl.so.11 libbpf.so.1 libelf.so.1 libcap.so.2 libz.so.1 \
      libnl-genl-3.so.200 libnl-3.so.200 libcap-ng.so.0 \
      libselinux.so.1 libpcre2-8.so.0 \
      libnftables.so.1 libedit.so.2 libjansson.so.4 libgmp.so.10 \
      libtinfo.so.6 libbsd.so.0 libmd.so.0; \
    do \
      cp "/lib/${triplet}/${lib}" "/staging/usr/lib/${triplet}/"; \
    done

FROM golang:1.27-trixie AS go-builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /entrypoint .

# Always installing whatever's current, same reasoning as the nordvpn
# package above — the weekly rebuild is what keeps this patched.
# hadolint ignore=DL3007
FROM gcr.io/distroless/base-debian13:latest

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

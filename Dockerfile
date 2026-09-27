# Install the real .deb on Debian, build a Go entrypoint (distroless has no
# shell), then copy only the binaries and the libraries ldd reports onto
# distroless. Not everything shows up in ldd: nordvpnd shells out by name to
# nft, sysctl and ps (procps) during connect/meshnet, so those are copied too.
#
# nordvpn and its apt deps are deliberately unpinned: the image tracks
# NordVPN's stable channel; upstream-check.yml rebuilds when an input moves.

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
    && apt-get install -y --no-install-recommends nordvpn iptables iproute2 wireguard-tools nftables procps

# distroless's own /etc/group, plus the `nordvpn` group (gid 999) the .deb's
# postinst created: the final stage only copies files, and norduserd fails
# every lookup without it.
# hadolint ignore=DL3007
COPY --from=gcr.io/distroless/base-debian13:latest /etc/group /etc/group.distroless-base

# Staged into one tree mirroring the final layout, because the multiarch
# triplet is only known here, at build time per --platform (hardcoding
# x86_64 once broke arm64).
#
# usr/lib/<triplet>, not lib/<triplet>: distroless's /lib is a usrmerge
# symlink and BuildKit's COPY refuses to write through it (the legacy builder
# doesn't mind, which hid this locally).
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) triplet=x86_64-linux-gnu ;; \
      arm64) triplet=aarch64-linux-gnu ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    mkdir -p /staging/usr/bin /staging/usr/sbin /staging/etc \
             /staging/usr/lib/nordvpn /staging/var/lib/nordvpn/data \
             "/staging/usr/lib/${triplet}"; \
    cp /etc/group.distroless-base /staging/etc/group; \
    grep '^nordvpn:' /etc/group >> /staging/etc/group; \
    cp /usr/bin/nordvpn /usr/bin/wg /staging/usr/bin/; \
    cp /usr/bin/ps /staging/usr/bin/; \
    cp /usr/sbin/nordvpnd /usr/sbin/iptables /usr/sbin/ip /usr/sbin/nft /usr/sbin/sysctl /staging/usr/sbin/; \
    cp -r /usr/lib/nordvpn/. /staging/usr/lib/nordvpn/; \
    cp -r /var/lib/nordvpn/data/. /staging/var/lib/nordvpn/data/; \
    for lib in \
      libgcc_s.so.1 libsqlite3.so.0 libxtables.so.12 libmnl.so.0 \
      libnftnl.so.11 libbpf.so.1 libelf.so.1 libcap.so.2 libz.so.1 \
      libnl-genl-3.so.200 libnl-3.so.200 libcap-ng.so.0 \
      libselinux.so.1 libpcre2-8.so.0 \
      libnftables.so.1 libedit.so.2 libjansson.so.4 libgmp.so.10 \
      libtinfo.so.6 libbsd.so.0 libmd.so.0 \
      libproc2.so.0 libsystemd.so.0; \
    do \
      cp "/lib/${triplet}/${lib}" "/staging/usr/lib/${triplet}/"; \
    done

FROM golang:1.27-trixie AS go-builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /entrypoint .

# unpinned, like the nordvpn package
# hadolint ignore=DL3007
FROM gcr.io/distroless/base-debian13:latest

# everything staged above, already at final paths
COPY --from=deb-builder /staging/ /

# nordvpn's bundled libraries live outside the default search path
ENV LD_LIBRARY_PATH=/usr/lib/nordvpn

COPY --from=go-builder /entrypoint /entrypoint

ENTRYPOINT ["/entrypoint"]

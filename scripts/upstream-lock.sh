#!/usr/bin/env bash
# Prints a fingerprint of every upstream input that can change the built image.
#
# The client and apt deps are unpinned on purpose (see the Dockerfile), so the
# same Dockerfile builds a different image week to week. Watching the inputs
# instead of a timer turns each upstream move into a normal release.
#
# Versions only, never image digests: base images get rebuilt with identical
# contents, and every such rebuild used to cut a release.
#
# Output: sorted key=value, diffed against the committed upstream.lock.

set -euo pipefail

cd "$(dirname "$0")/.."

# unattended daily run: without timeouts a stalled mirror holds the job for 6h
CURL_OPTS=(-fsSL --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 3)

# timeout only if available (macOS lacks it by default)
TIMEOUT=(); command -v timeout >/dev/null 2>&1 && TIMEOUT=(timeout 120)

# Every lookup goes through add(): a failed curl inside `echo "key=$(...)"`
# still exits 0, writing a lock of blanks (a PR a day, or masked changes).
# add() runs in the parent shell on purpose; `exit` inside $(...) only ends
# the subshell.
LOCK=""
add() {
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    echo "upstream-lock: could not resolve ${key}" >&2
    exit 1
  fi
  LOCK+="${key}=${value}"$'\n'
}

# --- the nordvpn client, from NordVPN's own apt channel -----------------------
# Their Packages index is the only feed they publish.
nordvpn_version() {
  curl "${CURL_OPTS[@]}" https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages \
    | awk '/^Package: nordvpn$/{p=1;next} /^$/{p=0} p&&/^Version:/{print $2}' \
    | sort -V | tail -n1
}

# --- Go toolchain --------------------------------------------------------------
# The entrypoint is a static binary, so the golang image only matters through
# its Go version (stdlib fixes). Minor comes from the Dockerfile so Dependabot's
# tag bumps carry over.
go_version() {
  local minor
  minor=$(sed -n 's/^FROM golang:\([0-9.]*\)-.*/\1/p' Dockerfile)
  [ -n "$minor" ] || return 0
  curl "${CURL_OPTS[@]}" 'https://go.dev/dl/?mode=json&include=all' \
    | jq -r --arg p "go${minor}." \
        '[.[] | select(.stable) | .version | select(startswith($p))][0] // empty'
}

# --- distroless runtime packages ---------------------------------------------
# Read from the image itself: Debian publishes fixes before distroless
# republishes, and releasing on Debian's version would ship the old package.
distroless_packages() {
  local cid
  cid=$(${TIMEOUT[@]+"${TIMEOUT[@]}"} docker create --platform linux/amd64 \
    gcr.io/distroless/base-debian13:latest none)
  ${TIMEOUT[@]+"${TIMEOUT[@]}"} docker cp "${cid}:/var/lib/dpkg/status.d" - \
    | tar -xO \
    | awk '$1=="Package:"{p=$2} $1=="Version:"{print p"="$2}'
  docker rm "$cid" >/dev/null
}

# --- apt dependency versions -------------------------------------------------
# Takes the higher of trixie and trixie-security: deb-builder runs
# apt-get upgrade, so that's exactly what gets copied.
#
# Main serves Packages.gz, security only Packages.xz; try both, since a 404
# here silently falls back to the main-suite version. Download to a file
# first: a stream dying mid-.xz would leave a partial index before the .gz
# fallback's copy.
fetch_index() {
  local base="$1" tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2064  # expand tmp now, not at trap time
  trap "rm -f '$tmp'" RETURN

  if curl "${CURL_OPTS[@]}" -o "$tmp" "${base}.xz" 2>/dev/null; then
    xz -dc "$tmp"
    return 0
  fi
  curl "${CURL_OPTS[@]}" -o "$tmp" "${base}.gz"
  gunzip -c "$tmp"
}

# Fetched once, not per package: each index is ~10MB.
MAIN_INDEX=$(mktemp)
SECURITY_INDEX=$(mktemp)
trap 'rm -f "$MAIN_INDEX" "$SECURITY_INDEX"' EXIT
fetch_index "http://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages" > "$MAIN_INDEX"
fetch_index "http://security.debian.org/debian-security/dists/trixie-security/main/binary-amd64/Packages" > "$SECURITY_INDEX"

apt_version() {
  awk -v p="$1" '$1=="Package:" {m=($2==p)} m&&$1=="Version:"{print $2}' \
    "$MAIN_INDEX" "$SECURITY_INDEX" \
    | sort -V | tail -n1
}

add "nordvpn" "$(nordvpn_version)"
add "go" "$(go_version)"

DISTROLESS=$(distroless_packages)
if [ -z "$DISTROLESS" ]; then
  echo "upstream-lock: could not resolve distroless packages" >&2
  exit 1
fi
while IFS='=' read -r pkg ver; do
  add "distroless:${pkg}" "$ver"
done <<< "$DISTROLESS"

# Everything copied out of deb-builder: the tools, plus the libs from the
# Dockerfile's `for lib in` list by owning package. nordvpn is above.
# ponytail: libs bundled in the .deb (/usr/lib/nordvpn) ride on the client version.
for pkg in iptables iproute2 nftables procps wireguard-tools \
  libbpf1 libbsd0 libcap-ng0 libcap2 libedit2 libelf1t64 libgcc-s1 libgmp10 \
  libjansson4 libmd0 libmnl0 libnftables1 libnftnl11 libnl-3-200 \
  libnl-genl-3-200 libpcre2-8-0 libproc2-0 libselinux1 libsqlite3-0 \
  libsystemd0 libtinfo6 libxtables12 zlib1g
do
  add "apt:${pkg}" "$(apt_version "$pkg")"
done

printf '%s' "$LOCK" | sort

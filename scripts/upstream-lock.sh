#!/usr/bin/env bash
# Prints a fingerprint of every upstream input that can change the built image.
#
# The client and apt deps are unpinned on purpose (see the Dockerfile), so the
# same Dockerfile builds a different image week to week. Watching the inputs
# instead of a timer turns each upstream move into a normal release.
#
# Output: sorted key=value, diffed against the committed upstream.lock.

set -euo pipefail

# unattended daily run: without timeouts a stalled mirror holds the job for 6h
CURL_OPTS=(-fsSL --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 3)

# --- the nordvpn client, from NordVPN's own apt channel -----------------------
# Their Packages index is the only feed they publish.
nordvpn_version() {
  curl "${CURL_OPTS[@]}" https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages \
    | awk '/^Package: nordvpn$/{p=1;next} /^$/{p=0} p&&/^Version:/{print $2}' \
    | sort -V | tail -n1
}

# --- base image digests ------------------------------------------------------
# By digest: distroless/base-debian13 is pinned to :latest, which Dependabot
# never sees move. timeout only if available (macOS lacks it by default).
TIMEOUT=(); command -v timeout >/dev/null 2>&1 && TIMEOUT=(timeout 120)

image_digest() {
  # ${arr[@]+"${arr[@]}"}: an empty array is unbound under set -u on macOS's old bash
  ${TIMEOUT[@]+"${TIMEOUT[@]}"} docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'
}

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

# --- apt dependency versions -------------------------------------------------
# Takes the higher of trixie and trixie-security: security updates change no
# tag we track elsewhere.
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

apt_version() {
  local pkg="$1" v=""
  for base in \
    "http://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages" \
    "http://security.debian.org/debian-security/dists/trixie-security/main/binary-amd64/Packages"
  do
    v+=$(fetch_index "$base" \
      | awk -v p="$pkg" '$1=="Package:" {m=($2==p)} m&&$1=="Version:"{print $2}' \
      | sort -V | tail -n1)$'\n'
  done
  printf '%s' "$v" | grep -v '^$' | sort -V | tail -n1
}

add "nordvpn" "$(nordvpn_version)"

for img in \
  "debian:trixie-slim" \
  "golang:1.27-trixie" \
  "gcr.io/distroless/base-debian13:latest"
do
  add "image:${img}" "$(image_digest "$img")"
done

# The runtime binaries copied out of deb-builder. nordvpn itself is above.
for pkg in iptables iproute2 nftables procps wireguard-tools; do
  add "apt:${pkg}" "$(apt_version "$pkg")"
done

printf '%s' "$LOCK" | sort

#!/usr/bin/env bash
# Prints a fingerprint of every upstream input that can change the built image.
#
# The image pins almost nothing on purpose (see the Dockerfile): the nordvpn
# client and its apt dependencies are installed unpinned so the image always
# ships what NordVPN and Debian currently publish. That is the right behaviour
# for a VPN client and the wrong behaviour for reproducibility -- the same
# Dockerfile builds a materially different image week to week, with no commit to
# hang a version off.
#
# Rebuilding weekly on a timer was the old answer, and it published images no
# semver could name. This is the other half: watch the inputs instead of the
# clock, so a rebuild happens when something upstream actually moves, and lands
# as a normal release.
#
# Output is a sorted key=value list, diffed against the committed upstream.lock.

set -euo pipefail

# This runs unattended on a daily schedule. Without timeouts a mirror that
# accepts the connection and then stalls holds the job open until GitHub's
# six-hour ceiling, and the failure reads as "check never finished" rather than
# "the mirror is down".
CURL_OPTS=(-fsSL --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 3)

# --- the nordvpn client, from NordVPN's own apt channel -----------------------
# Same parse as the old version check: their Packages index is the only feed
# they publish -- no tags, no releases, no RSS.
nordvpn_version() {
  curl "${CURL_OPTS[@]}" https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages \
    | awk '/^Package: nordvpn$/{p=1;next} /^$/{p=0} p&&/^Version:/{print $2}' \
    | sort -V | tail -n1
}

# --- base image digests ------------------------------------------------------
# By digest, not tag. distroless/base-debian13 is the reason this matters:
# it is pinned to :latest, so it moves under us with nothing to notice --
# Dependabot only sees tag changes, and that tag never changes.
# timeout for the same reason curl has one: a registry that hangs rather than
# refusing would otherwise stall the whole job. Not present on macOS by default,
# and this is worth being able to run locally, so it is used only if available.
TIMEOUT=(); command -v timeout >/dev/null 2>&1 && TIMEOUT=(timeout 120)

image_digest() {
  # ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": under set -u an empty array
  # is an unbound variable on older bash, which is what macOS ships.
  ${TIMEOUT[@]+"${TIMEOUT[@]}"} docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'
}

# Every lookup goes through add(). A failed curl or a missing binary makes the
# surrounding $(...) expand to nothing while `echo "key=$(...)"` still succeeds,
# so without a check the script exits 0 having written a lock full of empty
# values -- the worst outcome available, because the committed lock would then
# differ from every good run afterwards (a PR a day), or a real upstream change
# would be masked by a blank on both sides.
#
# add() runs in the parent shell on purpose. The obvious version of this guard
# sits inside the substitution -- `key=$(require ...)` -- where `exit` only ends
# the subshell and the script sails on. That version was written first and
# tested green against the happy path.
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
# Checks trixie and trixie-security and takes the higher: a security update to
# iptables or procps lands only in the security suite, changes no tag and no
# version string we track elsewhere, and is exactly the drift the weekly timer
# existed to catch.
#
# The two archives do not agree on compression: the main mirror serves
# Packages.gz, security serves Packages.xz only. Fetch whichever exists rather
# than assuming -- getting this wrong 404s silently per package and the function
# still returns the main-suite version, so security drift would go unnoticed,
# which is the one thing this is here to catch.
# Downloads to a file before decompressing rather than streaming. Streaming the
# .xz attempt straight to stdout means a mirror that dies mid-transfer has
# already emitted a partial index, and the .gz fallback then appends a second
# copy after it. sort -V | tail -n1 happens to survive that, so it would have
# produced right answers from corrupt input -- until the day it did not.
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

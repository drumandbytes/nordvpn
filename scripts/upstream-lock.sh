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

# --- the nordvpn client, from NordVPN's own apt channel -----------------------
# Same parse as the old version check: their Packages index is the only feed
# they publish -- no tags, no releases, no RSS.
nordvpn_version() {
  curl -fsSL https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages \
    | awk '/^Package: nordvpn$/{p=1;next} /^$/{p=0} p&&/^Version:/{print $2}' \
    | sort -V | tail -n1
}

# --- base image digests ------------------------------------------------------
# By digest, not tag. distroless/base-debian13 is the reason this matters:
# it is pinned to :latest, so it moves under us with nothing to notice --
# Dependabot only sees tag changes, and that tag never changes.
image_digest() {
  docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'
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
fetch_index() {
  local base="$1"
  if curl -fsSL "${base}.xz" 2>/dev/null | xz -dc 2>/dev/null; then return 0; fi
  curl -fsSL "${base}.gz" | gunzip
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

{
  echo "nordvpn=$(nordvpn_version)"

  for img in \
    "debian:trixie-slim" \
    "golang:1.27-trixie" \
    "gcr.io/distroless/base-debian13:latest"
  do
    echo "image:${img}=$(image_digest "$img")"
  done

  # The runtime binaries copied out of deb-builder. nordvpn itself is above.
  for pkg in iptables iproute2 nftables procps wireguard-tools; do
    echo "apt:${pkg}=$(apt_version "$pkg")"
  done
} | sort

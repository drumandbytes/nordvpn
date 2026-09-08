#!/usr/bin/env bash
# Deletes GHCR package versions that nothing can reach any more.
#
# Deleting a tag in the GHCR UI removes only the index. A multi-arch build with
# attestations publishes five to seven versions and tags one or two of them --
# the amd64 and arm64 manifests, the provenance manifests and the sha256-<digest>
# referrer are all untagged -- and GHCR garbage-collects none of them. After
# pruning ten date-tagged images by hand this package held 169 versions of which
# 25 were reachable.
#
# Reachability is resolved rather than guessed: every tag is inspected, its
# children collected, and anything untagged outside that set is an orphan. The
# same pass catches sha256-<digest> attestations whose subject image is already
# gone, which look tagged and are therefore easy to miss.
#
# Dry run by default. Pass --delete to actually remove anything.
#
# Needs: gh authenticated with read:packages and delete:packages, and docker
# buildx for the manifest inspection.

set -euo pipefail

ORG="${ORG:-drumandbytes}"
PKG="${PKG:-nordvpn}"
IMAGE="ghcr.io/${ORG}/${PKG}"
API="/orgs/${ORG}/packages/container/${PKG}/versions"

DELETE=false
[ "${1:-}" = "--delete" ] && DELETE=true

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# --paginate concatenates one JSON array per page rather than emitting a single
# array, so the pages are stitched before parsing. Reading only the first page is
# how the last manual pass missed a date tag: the cap is 100 and this package had
# 169 versions.
versions_json() {
  gh api "${API}?per_page=100" --paginate \
    | python3 -c 'import sys,json; print(json.dumps([v for page in json.loads("["+sys.stdin.read().replace("][","],[")+"]") for v in page]))'
}

echo "reading ${IMAGE} ..."
ALL=$(versions_json)
TOTAL=$(jq 'length' <<< "$ALL")

TAGS=$(jq -r '.[] | .metadata.container.tags[]?' <<< "$ALL")
[ -n "$TAGS" ] || { echo "no tagged versions found -- refusing to treat everything as unreachable" >&2; exit 1; }

# Every digest a tag names, plus every digest those manifests reference.
KEEP=$(mktemp); trap 'rm -f "$KEEP"' EXIT
while read -r tag; do
  [ -n "$tag" ] || continue
  raw=$(docker buildx imagetools inspect "${IMAGE}:${tag}" --raw 2>/dev/null) || {
    echo "  WARN could not inspect ${tag} -- treating its children as reachable is impossible, aborting" >&2
    exit 1
  }
  docker buildx imagetools inspect "${IMAGE}:${tag}" --format '{{.Manifest.Digest}}' 2>/dev/null | sed 's/^sha256://' >> "$KEEP"
  jq -r '.manifests[]?.digest // empty' <<< "$raw" | sed 's/^sha256://' >> "$KEEP"
done <<< "$TAGS"
sort -u -o "$KEEP" "$KEEP"

echo "  ${TOTAL} versions, $(wc -l < "$KEEP" | tr -d ' ') digests reachable from tags"

# Untagged and unreachable, plus attestations whose subject no longer exists.
LIVE_DIGESTS=$(jq -r '.[].name' <<< "$ALL" | sed 's/^sha256://' | sort -u)
ORPHANS=$(jq -r --rawfile keep "$KEEP" --arg live "$LIVE_DIGESTS" '
  ($keep | split("\n") | map(select(length>0))) as $k
  | ($live | split("\n")) as $l
  | .[]
  | . as $v
  | ($v.name | sub("^sha256:";"")) as $d
  | ($v.metadata.container.tags // []) as $t
  | if ($t | length) == 0 then
      (if ($k | index($d)) then empty else "\($v.id) untagged \($d[0:12])" end)
    else
      ($t[] | select(test("^sha256-[0-9a-f]{64}$")) | sub("^sha256-";"")) as $subject
      | if ($l | index($subject)) then empty else "\($v.id) orphaned-attestation \($subject[0:12])" end
    end
' <<< "$ALL")

COUNT=$(printf '%s' "$ORPHANS" | grep -c . || true)
if [ "$COUNT" -eq 0 ]; then
  echo "  nothing to prune"
  exit 0
fi

echo "  ${COUNT} unreachable:"
printf '%s\n' "$ORPHANS" | sed 's/^/    /'

if ! $DELETE; then
  echo
  echo "dry run -- pass --delete to remove these"
  exit 0
fi

echo
while read -r id kind detail; do
  [ -n "$id" ] || continue
  # Re-read immediately before deleting: an id alone is not proof, and the
  # listing above may be minutes old by the time the loop reaches the end.
  n=$(gh api "${API}/${id}" -q '.metadata.container.tags | length' 2>/dev/null || echo "?")
  if [ "$kind" = "untagged" ] && [ "$n" != "0" ]; then
    echo "  ${id} REFUSED -- now carries ${n} tag(s)"
    continue
  fi
  if gh api -X DELETE "${API}/${id}" >/dev/null 2>&1; then
    echo "  ${id} ${kind} ${detail} deleted"
  else
    echo "  ${id} FAILED"
  fi
done <<< "$ORPHANS"

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
# v1 (#23) built its keep-set by inspecting only *tagged* refs, one level deep:
# for each tag, collect the digests its manifest points at, done. The three
# sha256-<digest> attestation tags contributed none of their own children to
# that set -- 15 digests kept where a correct pass keeps 21 -- so the untagged
# attestation manifests underneath them read as orphans and were deleted (#21,
# reverted in 3b2dd55). The images were never at risk; the attestations were,
# and they were what went unchecked.
#
# This version walks a full reference graph instead: starting from every
# digest a real tag names, it recursively inspects BY DIGEST -- not by tag --
# and keeps following .manifests[] and .layers[] children for as long as
# there are any. A sha256-<digest> attestation tag is folded in as an extra
# root once its subject digest is confirmed reachable, and its own children
# are then walked the same way. Nothing about reachability depends on which
# things happen to be tagged beyond that seed.
#
# Dry run by default. Pass --delete to actually remove anything. Anything
# newer than MIN_AGE_HOURS (default 24) is reported but never deleted, so a
# build still in flight can't be pruned mid-push.
#
# Pass --self-test to run the graph algorithm against a fixed, generated
# fixture reproducing the v1 shape (one release indexing two per-arch
# manifests, each with its own attestation index fanning out to two
# untagged attestation manifests, plus a plain orphan and an attestation
# whose subject is already gone) and check the result against a hand-derived
# expectation. No gh, no docker, no network -- this is what should have
# caught v1's bug before it ran against the real package, and it's the
# thing to run first after touching the algorithm below.
#
# Needs: gh authenticated with read:packages and delete:packages, and docker
# buildx for manifest inspection. --self-test needs only jq and python3.

set -euo pipefail

ORG="${ORG:-drumandbytes}"
PKG="${PKG:-nordvpn}"
IMAGE="ghcr.io/${ORG}/${PKG}"
API="/orgs/${ORG}/packages/container/${PKG}/versions"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-24}"

DELETE=false
SELF_TEST=false
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE=true ;;
    --self-test) SELF_TEST=true ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
if $SELF_TEST; then
  command -v python3 >/dev/null || { echo "python3 is required for --self-test" >&2; exit 1; }
else
  command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
  command -v docker >/dev/null || { echo "docker buildx is required" >&2; exit 1; }
fi

# --- version listing -----------------------------------------------------
# --paginate concatenates one JSON array per page rather than emitting a
# single array, so the pages are stitched before parsing. Reading only the
# first page is how a date tag survived v1's first manual sweep: the cap is
# 100 and this package had 169 versions.
versions_json() {
  gh api "${API}?per_page=100" --paginate \
    | python3 -c 'import sys,json; print(json.dumps([v for page in json.loads("["+sys.stdin.read().replace("][","],[")+"]") for v in page]))'
}

# --- the fixed fixture for --self-test ------------------------------------
# Digests are sha256 hashes of the node names below, generated rather than
# typed, so there is no way for a keep-set digest and a raw-manifest digest
# to silently drift apart in the fixture itself.
generate_fixture() {
  python3 - <<'PY'
import hashlib, json

def d(name):
    return hashlib.sha256(name.encode()).hexdigest()

names = [
    "root", "amd64", "arm64",
    "att_amd64", "att_arm64",
    "att_amd64_a", "att_amd64_b", "att_arm64_a", "att_arm64_b",
    "orphan", "dangling",
]
digest = {n: d(n) for n in names}
ghost_digest = d("ghost")  # references this on purpose; it names no version

def ver(id_, name, tags):
    return {
        "id": id_,
        "name": "sha256:" + digest[name],
        "created_at": "2020-01-01T00:00:00Z",
        "metadata": {"container": {"tags": tags}},
    }

all_versions = [
    ver(1, "root", ["1.1.0"]),
    ver(2, "amd64", []),
    ver(3, "arm64", []),
    ver(4, "att_amd64", ["sha256-" + digest["amd64"]]),
    ver(5, "att_arm64", ["sha256-" + digest["arm64"]]),
    ver(6, "att_amd64_a", []),
    ver(7, "att_amd64_b", []),
    ver(8, "att_arm64_a", []),
    ver(9, "att_arm64_b", []),
    ver(10, "orphan", []),
    ver(11, "dangling", ["sha256-" + ghost_digest]),
]

def idx(*children):
    return {"manifests": [{"digest": "sha256:" + digest[c]} for c in children]}

raw = {
    digest["root"]: idx("amd64", "arm64"),
    digest["amd64"]: {},
    digest["arm64"]: {},
    digest["att_amd64"]: idx("att_amd64_a", "att_amd64_b"),
    digest["att_arm64"]: idx("att_arm64_a", "att_arm64_b"),
    digest["att_amd64_a"]: {},
    digest["att_amd64_b"]: {},
    digest["att_arm64_a"]: {},
    digest["att_arm64_b"]: {},
    digest["orphan"]: {},
    digest["dangling"]: {},
}

print(json.dumps({
    "all": all_versions,
    "raw": raw,
    # root+amd64+arm64+2 attestation indexes+4 attestation manifests = 9,
    # matching the incident's own arithmetic at a scale worth hand-checking:
    # this is the shape v1 got wrong (15 kept where 21 was correct).
    "expect_keep_ids": [1, 2, 3, 4, 5, 6, 7, 8, 9],
    "expect_orphan_ids": [10, 11],
}))
PY
}

if $SELF_TEST; then
  FIXTURE=$(generate_fixture)
  ALL=$(jq -c '.all' <<<"$FIXTURE")
  FIXTURE_RAW=$(jq -c '.raw' <<<"$FIXTURE")
else
  echo "reading ${IMAGE} ..."
  ALL=$(versions_json)
fi

TOTAL=$(jq 'length' <<< "$ALL")

# --- graph primitives ------------------------------------------------------
# A version's children are whatever its manifest points at: .manifests[] for
# an index (a release, or an attestation index fanning out to per-arch
# attestation manifests), .layers[] for a single manifest (an attestation
# manifest pointing at its sigstore bundle blob). Both are checked every
# time -- nothing here assumes in advance which shape a given digest is.
children_of() {
  jq -r '(.manifests[]?.digest // empty), (.layers[]?.digest // empty)' <<<"$1" | sed 's/^sha256://'
}

inspect_by_digest() {
  local d="$1"
  if $SELF_TEST; then
    jq -e --arg d "$d" '.[$d] // empty' <<<"$FIXTURE_RAW" 2>/dev/null
  else
    docker buildx imagetools inspect "${IMAGE}@sha256:${d}" --raw 2>/dev/null
  fi
}

declare -A VISITED
QUEUE=()

enqueue() {
  local d="$1"
  [ -n "$d" ] || return 0
  [ -n "${VISITED[$d]:-}" ] && return 0
  VISITED[$d]=1
  QUEUE+=("$d")
}

# A failed inspect on something already in the graph as someone's child is
# just a leaf blob (a layer has no further children of its own) -- not an
# error. A failed inspect on a *root* is different: a named tag or a
# validated attestation tag that doesn't resolve means something is wrong
# with the very thing the keep-set is anchored on, and guessing its
# children is how v1 went wrong. Roots are inspected explicitly below and
# abort the run if they don't resolve; drain() only ever sees non-roots.
drain() {
  while [ ${#QUEUE[@]} -gt 0 ]; do
    local d="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")
    local raw
    raw=$(inspect_by_digest "$d") || continue
    [ -n "$raw" ] || continue
    local c
    while IFS= read -r c; do
      enqueue "$c"
    done < <(children_of "$raw")
  done
}

add_root() {
  local d="$1" raw
  raw=$(inspect_by_digest "$d") || { echo "WARN could not inspect root ${d} -- aborting" >&2; exit 1; }
  enqueue "$d"
  local c
  while IFS= read -r c; do
    enqueue "$c"
  done < <(children_of "$raw")
}

# Phase 1: every digest a real (non sha256-<digest>) tag names, and
# everything reachable from it.
NAMED_DIGESTS=$(jq -r '
  .[]
  | select((.metadata.container.tags // []) | map(select(test("^sha256-[0-9a-f]{64}$") | not)) | length > 0)
  | (.name | sub("^sha256:";""))
' <<<"$ALL")
[ -n "$NAMED_DIGESTS" ] || { echo "no named tags found -- refusing to treat everything as unreachable" >&2; exit 1; }

while IFS= read -r d; do
  [ -n "$d" ] || continue
  add_root "$d"
done <<<"$NAMED_DIGESTS"
drain

# Phase 2: sha256-<digest> attestation tags whose subject is now known
# reachable are roots too -- fold in their own digest and walk their
# children the same way. An attestation whose subject isn't reachable
# (already deleted, or never was) stays unpromoted and falls out as an
# orphan below, tag or no tag.
ATT_ROWS=$(jq -r '
  .[]
  | (.name | sub("^sha256:";"")) as $own
  | (.metadata.container.tags // [])[]
  | select(test("^sha256-[0-9a-f]{64}$"))
  | sub("^sha256-";"") + " " + $own
' <<<"$ALL")

while IFS=' ' read -r subject own; do
  [ -n "$subject" ] || continue
  [ -n "${VISITED[$subject]:-}" ] || continue
  add_root "$own"
done <<<"$ATT_ROWS"
drain

echo "  ${TOTAL} versions, ${#VISITED[@]} digests reachable"

# --- orphans -----------------------------------------------------------
# Anything not in VISITED, tagged or not: an untagged manifest nothing
# points at, or an attestation tag whose subject is gone.
#
# tags defaults to "-", never "": IFS=$'\t' read still treats tab as IFS
# whitespace even when it's the only character in IFS, so it collapses
# consecutive delimiters instead of yielding an empty field -- an untagged
# row's empty tags column would otherwise vanish and shift created_at left
# into its place.
ORPHAN_ROWS=()
while IFS=$'\t' read -r id digest tags created_at; do
  [ -n "${VISITED[$digest]:-}" ] && continue
  ORPHAN_ROWS+=("${id}"$'\t'"${digest}"$'\t'"${tags}"$'\t'"${created_at}")
done < <(jq -r '.[] | [.id, (.name | sub("^sha256:";"")), ((.metadata.container.tags // []) | if length == 0 then "-" else join(",") end), .created_at] | @tsv' <<<"$ALL")

if $SELF_TEST; then
  ACTUAL_KEEP=$(jq -c --argjson visited "$(printf '%s\n' "${!VISITED[@]}" | jq -R . | jq -sc .)" '
    [.[] | select((.name | sub("^sha256:";"")) as $d | $visited | index($d)) | .id] | sort
  ' <<<"$ALL")
  ACTUAL_ORPHAN=$(printf '%s\n' "${ORPHAN_ROWS[@]}" | awk -F'\t' 'NF{print $1}' | jq -cRn '[inputs | tonumber] | sort')
  EXPECT_KEEP=$(jq -c '.expect_keep_ids | sort' <<<"$FIXTURE")
  EXPECT_ORPHAN=$(jq -c '.expect_orphan_ids | sort' <<<"$FIXTURE")

  ok=true
  if [ "$ACTUAL_KEEP" != "$EXPECT_KEEP" ]; then
    echo "FAIL keep-set: expected ${EXPECT_KEEP}, got ${ACTUAL_KEEP}" >&2
    ok=false
  fi
  if [ "$ACTUAL_ORPHAN" != "$EXPECT_ORPHAN" ]; then
    echo "FAIL orphan-set: expected ${EXPECT_ORPHAN}, got ${ACTUAL_ORPHAN}" >&2
    ok=false
  fi
  if $ok; then
    echo "PASS: keep=${ACTUAL_KEEP} orphan=${ACTUAL_ORPHAN}"
    exit 0
  fi
  exit 1
fi

if [ ${#ORPHAN_ROWS[@]} -eq 0 ]; then
  echo "  nothing to prune"
  exit 0
fi

echo "  ${#ORPHAN_ROWS[@]} unreachable:"
now_epoch=$(date -u +%s)
min_age_seconds=$(( MIN_AGE_HOURS * 3600 ))

TO_DELETE=()
for row in "${ORPHAN_ROWS[@]}"; do
  IFS=$'\t' read -r id digest tags created_at <<<"$row"
  kind="untagged"
  [ "$tags" != "-" ] && kind="tagged(${tags})"

  created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null || echo "$now_epoch")
  age=$(( now_epoch - created_epoch ))
  if [ "$age" -lt "$min_age_seconds" ]; then
    echo "    ${id} ${kind} ${digest:0:12} -- $(( age / 3600 ))h old, younger than ${MIN_AGE_HOURS}h, skipping this run"
    continue
  fi

  echo "    ${id} ${kind} ${digest:0:12}"
  TO_DELETE+=("$id")
done

if ! $DELETE; then
  echo
  echo "dry run -- pass --delete to remove the versions listed above (not the ones skipped as too young)"
  exit 0
fi

echo
for id in "${TO_DELETE[@]}"; do
  # Re-read immediately before deleting: the listing above may be minutes
  # old by the time a long loop gets here, and an id alone is not proof of
  # what it currently points at. Checked against *named* tags specifically
  # -- a dangling attestation orphan always carries its own sha256-<digest>
  # tag, so a plain "any tag at all" check would refuse to ever delete it.
  n=$(gh api "${API}/${id}" -q '[(.metadata.container.tags // [])[] | select(test("^sha256-[0-9a-f]{64}$") | not)] | length' 2>/dev/null || echo "?")
  if [ "$n" != "0" ]; then
    echo "  ${id} REFUSED -- now carries a named tag"
    continue
  fi
  if gh api -X DELETE "${API}/${id}" >/dev/null 2>&1; then
    echo "  ${id} deleted"
  else
    echo "  ${id} FAILED"
  fi
done

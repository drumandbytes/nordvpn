#!/usr/bin/env bash
# Deletes GHCR package versions nothing can reach any more.
#
# Deleting a tag in the GHCR UI removes only the index; the per-arch manifests,
# provenance manifests and sha256-<digest> referrers stay untagged and GHCR
# never collects them.
#
# Walks the full reference graph BY DIGEST from every real tag, following
# .manifests[] and .layers[]. A sha256-<digest> attestation tag becomes a root
# once its subject is reachable. v1 (#23) only looked one level below tagged
# refs and deleted reachable attestations (#21, reverted in 3b2dd55).
#
# Dry run by default; --delete to remove. Anything newer than MIN_AGE_HOURS
# (default 24) is never deleted, so an in-flight build can't be pruned.
# --self-test checks the algorithm against a generated fixture of v1's
# failure shape (no gh/docker/network; needs jq and python3). Run it after
# touching the graph code.
#
# Needs: gh with read:packages and delete:packages, docker buildx.

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
# --paginate emits one array per page; stitch them. The cap is 100 and this
# package had 169 versions.
versions_json() {
  gh api "${API}?per_page=100" --paginate \
    | python3 -c 'import sys,json; print(json.dumps([v for page in json.loads("["+sys.stdin.read().replace("][","],[")+"]") for v in page]))'
}

# --- the fixed fixture for --self-test ------------------------------------
# Digests are generated from node names so fixture and keep-set can't drift.
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
    # 9 kept: root+amd64+arm64+2 attestation indexes+4 attestation manifests (v1's shape)
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
# Children: .manifests[] for an index, .layers[] for a manifest; both always checked.
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

# A failed inspect on a child is just a leaf blob. A root that doesn't
# resolve aborts the run: guessing its children is how v1 went wrong. Roots
# are inspected explicitly below; drain() only sees non-roots.
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

# Phase 1: every digest a real (non sha256-<digest>) tag names, and what it reaches.
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

# Phase 2: attestation tags whose subject is reachable become roots too.
# Unreachable subjects fall out as orphans below.
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
# Anything not in VISITED, tagged or not.
#
# tags defaults to "-", never "": `IFS=$'\t' read` collapses consecutive tabs,
# so an empty column would shift created_at left.
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
  # Re-read right before deleting: the listing may be minutes old. Checks
  # *named* tags only, since dangling attestations carry their own sha256- tag.
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

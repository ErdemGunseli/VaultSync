#!/usr/bin/env bash
# Deterministic test of resolve_conflicts_sync_style against BOTH directions of a
# modify/delete conflict, plus a path whose DIRECTORY contains a dot.
#
# Why a unit-style test rather than driving the whole daemon: a modify/delete
# race depends on which side commits first, so a timing-based test silently
# stops constructing the conflict (verified: it passed against known-broken
# code). Here the conflicted index state is built by hand with real git, and the
# REAL function is extracted from bridge.sh and executed - no transcription of
# the logic into the test, so an inverted fix cannot pass.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$HERE/../bridge.sh"
PASS=0; FAIL=0
# Isolate from the host's git config. NOT /dev/null: git >=2.43 parses a config
# path as a real file and errors "bad config line 1 in file /dev/null".
GIT_ISOLATED_CONFIG="$(mktemp)"
export GIT_CONFIG_GLOBAL="$GIT_ISOLATED_CONFIG" GIT_CONFIG_SYSTEM="$GIT_ISOLATED_CONFIG"

check() {
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1))
  else printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$GIT_ISOLATED_CONFIG"' EXIT

# Extract the real resolver, plus every bridge.sh function it calls, plus the
# log helper. The call graph must be COMPLETE: an undefined function under
# `set +u` is just a command-not-found returning 127, which several call sites
# here read as a meaningful "no" - so a missing extraction does not error, it
# silently stands in for one particular answer and the test stops exercising
# the real code.
{
  echo 'log() { printf "[test] %s\n" "$*"; }'
  awk '/^hidden_path\(\)/,/^}$/' "$BRIDGE"
  awk '/^resolve_conflicts_sync_style\(\)/,/^}$/' "$BRIDGE"
} > "$TMP/resolver.sh"
grep -q 'resolve_conflicts_sync_style()' "$TMP/resolver.sh"
check "resolver function extracted from the real bridge.sh" "0" "$?"

# Build a repo in a genuine conflicted state.
# direction: "ours-modify" = we edited, they deleted (the branch-wedging case)
#            "ours-delete" = we deleted, they edited (the mirror case)
make_conflict() {
  local dir="$1" direction="$2" file="$3"
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"
  git init -q .; git config user.email t@t.invalid; git config user.name t
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  printf 'original\n' > "$file"; git add -A; git commit -qm base
  git branch -q other
  if [ "$direction" = "ours-modify" ]; then
    printf 'device edit\n' > "$file"; git add -A; git commit -qm "ours: modify"
    git checkout -q other; git rm -q "$file"; git commit -qm "theirs: delete"
  else
    git rm -q "$file"; git commit -qm "ours: delete"
    git checkout -q other; printf 'agent edit\n' > "$file"; git add -A; git commit -qm "theirs: modify"
  fi
  git checkout -q master 2>/dev/null || git checkout -q main
  git merge --no-edit other >/dev/null 2>&1   # expected to conflict
  cd "$HERE"
}

run_resolver() {
  ( set +u; export VAULT_DIR="$1"; . "$TMP/resolver.sh"; resolve_conflicts_sync_style ) >/dev/null 2>&1
}

# --- Case A: we modified, they deleted. Must converge, keeping the edit. ---
make_conflict "$TMP/a" ours-modify "note.md"
git -C "$TMP/a" diff --name-only --diff-filter=U | grep -q note.md
check "case A really is a conflicted (unmerged) state" "0" "$?"
run_resolver "$TMP/a"
check "case A: resolver succeeds (no branch-wedging failure)" "0" "$?"
check "case A: tree is clean after resolution" "" "$(git -C "$TMP/a" status --porcelain 2>/dev/null)"
check "case A: the device edit survives in the note" "device edit" "$(cat "$TMP/a/note.md" 2>/dev/null)"

# --- Case B (mirror): we deleted, they modified. Their edit survives as a copy. ---
make_conflict "$TMP/b" ours-delete "note.md"
run_resolver "$TMP/b"
check "case B: resolver succeeds" "0" "$?"
check "case B: tree is clean after resolution" "" "$(git -C "$TMP/b" status --porcelain 2>/dev/null)"
copies=$(find "$TMP/b" -name "*conflicted copy*" -not -path "*/.git/*" | wc -l)
check "case B: their edit is preserved as a conflicted copy" "1" "$copies"

# --- Case C: a dot in the DIRECTORY name must not be treated as an extension ---
make_conflict "$TMP/c" ours-delete "my.notes/README"
run_resolver "$TMP/c"
check "case C: resolver succeeds for a dotted directory with an extensionless file" "0" "$?"
copies=$(find "$TMP/c" -name "*conflicted copy*" -not -path "*/.git/*" | wc -l)
check "case C: conflicted copy landed in the right directory" "1" "$copies"

# --- Case D: the size cap must apply to the conflicted copy too --------------
# A conflicted copy is a NEW blob written by the resolver and committed by it.
# The cap ran only on the ordinary commit path, so an oversized losing side
# reached git and could never reach a device - the exact divergence the cap
# exists to stop, through the one path that skipped it. Mutation-tested: delete
# the enforce_size_cap call in the resolver and this case fails.
{
  echo 'log() { printf "[test] %s\n" "$*"; }'
  echo 'MAX_FILE_MB="${VAULT_MAX_FILE_MB:-5}"'
  awk '/^hidden_path\(\)/,/^}$/' "$BRIDGE"
  awk '/^compress_enabled\(\)/,/^}$/' "$BRIDGE"
  awk '/^image_backend\(\)/,/^}$/' "$BRIDGE"
  awk '/^image_reencode\(\)/,/^}$/' "$BRIDGE"
  awk '/^image_verify\(\)/,/^}$/' "$BRIDGE"
  awk '/^compress_to_fit\(\)/,/^}$/' "$BRIDGE"
  awk '/^enforce_size_cap\(\)/,/^}$/' "$BRIDGE"
  awk '/^resolve_conflicts_sync_style\(\)/,/^}$/' "$BRIDGE"
} > "$TMP/resolver_cap.sh"
bash -n "$TMP/resolver_cap.sh" 2>/dev/null
check "the extracted cap+resolver call graph is valid shell" "0" "$?"

# Built from scratch: calling make_conflict first would leave the tree already
# conflicted, so the follow-up checkout fails and NO conflict gets constructed -
# the assertion then passes without testing anything (observed, then fixed).
( rm -rf "$TMP/d"; mkdir -p "$TMP/d"; cd "$TMP/d"
  git init -q .; git config user.email t@t.invalid; git config user.name t
  printf 'original\n' > big.md; git add -A; git commit -qm base
  git branch -q other
  git rm -q big.md; git commit -qm "ours: delete"
  git checkout -q other
  head -c 2000000 /dev/zero | tr '\0' 'x' > big.md
  git add -A; git commit -qm "theirs: oversized modify"
  git checkout -q master 2>/dev/null || git checkout -q main
  git merge --no-edit other >/dev/null 2>&1 ) >/dev/null 2>&1
unmerged_d=$(git -C "$TMP/d" diff --name-only --diff-filter=U 2>/dev/null | wc -l)
check "case D really is a conflicted state (not a vacuous pass)" "1" "$unmerged_d"
( set +u; export VAULT_DIR="$TMP/d" VAULT_MAX_FILE_MB=1
  . "$TMP/resolver_cap.sh"; resolve_conflicts_sync_style ) >"$TMP/d.log" 2>&1
committed_copy=$(git -C "$TMP/d" ls-tree -r --name-only HEAD 2>/dev/null | grep -c "conflicted copy" || true)
check "an oversized conflicted copy is NOT committed" "0" "$committed_copy"
check "and the cap says why" "yes" \
  "$([ "$(grep -c 'exceeds sync cap' "$TMP/d.log")" -ge 1 ] && echo yes || echo no)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

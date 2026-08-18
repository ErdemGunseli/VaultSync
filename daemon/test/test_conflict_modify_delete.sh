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

# Extract the real resolver (and the log helper it calls) from bridge.sh.
{
  echo 'log() { printf "[test] %s\n" "$*"; }'
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

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

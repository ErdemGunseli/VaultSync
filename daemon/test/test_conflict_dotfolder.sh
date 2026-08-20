#!/usr/bin/env bash
# A conflicted copy is a SURFACING mechanism, so one that cannot surface is a
# defect, not a resolution.
#
# resolve_conflicts_sync_style used to iterate every unmerged path with no
# filter, so a collision on '.agent-memory/sessions/x.md' produced
# '.agent-memory/sessions/x (conflicted copy <ts>).md' - committed, pushed, and
# rendered by nothing: Obsidian shows neither dotfolders nor dotfiles. The vault
# repo's own .gitignore keeps conflicted copies UNignored precisely so they
# "appear on every device, inside Obsidian", which a hidden one never does. Its
# only trace was one log line.
#
# The fix routes a hidden-path collision to the pre-existing loud branch: no
# copy, the caller aborts the merge, a WARNING says why, and a human resolves
# it. These tests pin that, and pin just as hard that ordinary notes still get
# their copy - a fix that silently disabled the whole mechanism would otherwise
# look identical from the outside.
#
# Style follows test_conflict_modify_delete.sh: the conflicted index is built by
# hand with real git, the REAL functions are extracted from bridge.sh and run,
# and every case asserts the conflict was actually constructed before asserting
# what happened to it. A timing-driven version of this test would silently stop
# building the conflict and pass against anything.
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

await() {
  local secs="$1"; shift
  local i=0
  while [ "$i" -lt "$((secs * 2))" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

TMP="$(mktemp -d)"
BRIDGE_PID=""
trap '[ -n "$BRIDGE_PID" ] && kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP" "$GIT_ISOLATED_CONFIG"' EXIT

# Pull a function out of bridge.sh verbatim. Matching on the literal "name()" at
# column 1 keeps this free of regex escaping, and the range ends at the first
# line that is exactly '}'.
extract_fn() { awk -v fn="$1" 'index($0, fn "()") == 1, /^}$/' "$BRIDGE"; }

# The resolver's whole call graph, real code only. enforce_size_cap and the
# compression helpers come along because the resolver calls them; leaving them
# out would make every case fail for a reason unrelated to what it tests.
{
  echo 'log() { printf "[test] %s\n" "$*"; }'
  echo 'MAX_FILE_MB="${VAULT_MAX_FILE_MB:-5}"'
  extract_fn hidden_path
  extract_fn compress_enabled
  extract_fn image_backend
  extract_fn image_reencode
  extract_fn compress_to_fit
  extract_fn enforce_size_cap
  extract_fn resolve_conflicts_sync_style
} > "$TMP/resolver.sh"

bash -n "$TMP/resolver.sh" 2>/dev/null
check "the extracted call graph is valid shell (real code, not a transcription)" "0" "$?"
grep -q 'resolve_conflicts_sync_style()' "$TMP/resolver.sh"
check "resolver function extracted from the real bridge.sh" "0" "$?"
grep -q 'hidden_path()' "$TMP/resolver.sh"
check "hidden-path predicate extracted from the real bridge.sh" "0" "$?"

# Build a repo where every named path is in a genuine same-region collision.
make_clash() {
  local dir="$1"; shift
  local p
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir" || return 1
  git init -q .; git config user.email t@t.invalid; git config user.name t
  for p in "$@"; do mkdir -p "$(dirname "$p")"; printf 'base\n' > "$p"; done
  git add -A; git commit -qm base
  git branch -q other
  for p in "$@"; do printf 'device side\n' > "$p"; done
  git add -A; git commit -qm ours
  git checkout -q other
  for p in "$@"; do printf 'agent side\n' > "$p"; done
  git add -A; git commit -qm theirs
  git checkout -q master 2>/dev/null || git checkout -q main
  git merge --no-edit other >/dev/null 2>&1   # expected to conflict
  cd "$HERE" || return 1
}

unmerged_count() { git -C "$1" diff --name-only --diff-filter=U 2>/dev/null | wc -l; }
copy_count() { find "$1" -name "*conflicted copy*" -not -path "*/.git/*" 2>/dev/null | wc -l; }
run_resolver() {
  ( set +u; export VAULT_DIR="$1"; . "$TMP/resolver.sh"; resolve_conflicts_sync_style ) >"$2" 2>&1
}

# --- Case A: a dotfolder collision must NOT produce an invisible copy --------
make_clash "$TMP/a" ".agent-memory/sessions/foo.md"
check "case A really is a conflicted state" "1" "$(unmerged_count "$TMP/a")"
head_before="$(git -C "$TMP/a" rev-parse HEAD)"
run_resolver "$TMP/a" "$TMP/a.log"; rc=$?
check "case A: the resolver refuses rather than resolving" "1" "$rc"
check "case A: no conflicted copy was written anywhere" "0" "$(copy_count "$TMP/a")"
check "case A: nothing was committed" "$head_before" "$(git -C "$TMP/a" rev-parse HEAD)"
check "case A: the collision is still unmerged, so the caller can abort it" "1" "$(unmerged_count "$TMP/a")"
check "case A: the WARNING names the offending path" "yes" \
  "$(grep -q "\.agent-memory/sessions/foo\.md" "$TMP/a.log" && echo yes || echo no)"
check "case A: and says no copy was made, so the log is not the only clue" "yes" \
  "$(grep -q 'NO conflicted copy was made' "$TMP/a.log" && echo yes || echo no)"
# The caller's fallback is `git merge --abort`; it only works because the
# resolver left the merge untouched. Prove the tree really is recoverable.
git -C "$TMP/a" merge --abort >/dev/null 2>&1
check "case A: merge --abort then succeeds" "0" "$?"
check "case A: and leaves a clean working tree" "" "$(git -C "$TMP/a" status --porcelain 2>/dev/null)"
check "case A: with the device's own version intact" "device side" \
  "$(cat "$TMP/a/.agent-memory/sessions/foo.md" 2>/dev/null)"

# --- Case B: .obsidian/ takes the SAME path, deliberately --------------------
# It is the dotfolder that collides most often in practice, which is exactly the
# argument for including it: it would be the largest source of copies no device
# can render. Its files are also machine-read config, not prose - nobody
# reconciles two versions of community-plugins.json by reading them side by
# side, so a copy there is litter rather than a decision surface. The cost is
# real and accepted: git sync stalls, loudly, until a human resolves it.
make_clash "$TMP/b" ".obsidian/appearance.json"
check "case B really is a conflicted state" "1" "$(unmerged_count "$TMP/b")"
run_resolver "$TMP/b" "$TMP/b.log"; rc=$?
check "case B: .obsidian/ is refused too, not carved out" "1" "$rc"
check "case B: no conflicted copy under .obsidian/" "0" "$(copy_count "$TMP/b")"
check "case B: the WARNING names the .obsidian path" "yes" \
  "$(grep -q "\.obsidian/appearance\.json" "$TMP/b.log" && echo yes || echo no)"

# --- Case C: a dotFILE at the repo root is hidden in Obsidian too ------------
# '.gitignore' would have become ' (conflicted copy <ts>).gitignore' - hidden,
# and with a leading space in the name for good measure.
make_clash "$TMP/c" ".gitignore"
check "case C really is a conflicted state" "1" "$(unmerged_count "$TMP/c")"
run_resolver "$TMP/c" "$TMP/c.log"; rc=$?
check "case C: a root dotfile is refused as well" "1" "$rc"
check "case C: no conflicted copy for the dotfile" "0" "$(copy_count "$TMP/c")"

# --- Case D: the ordinary case must still work (the anti-overreach guard) ----
# A fix that simply stopped making copies would pass every case above.
make_clash "$TMP/d" "note.md"
check "case D really is a conflicted state" "1" "$(unmerged_count "$TMP/d")"
head_before="$(git -C "$TMP/d" rev-parse HEAD)"
run_resolver "$TMP/d" "$TMP/d.log"; rc=$?
check "case D: a visible note still resolves Sync-style" "0" "$rc"
check "case D: exactly one conflicted copy is written" "1" "$(copy_count "$TMP/d")"
check "case D: the device side stays in the note" "device side" "$(cat "$TMP/d/note.md" 2>/dev/null)"
check "case D: the copy carries the other side" "agent side" \
  "$(cat "$(find "$TMP/d" -name "*conflicted copy*" -not -path "*/.git/*" | head -1)" 2>/dev/null)"
check "case D: the resolution was committed" "yes" \
  "$([ "$(git -C "$TMP/d" rev-parse HEAD)" != "$head_before" ] && echo yes || echo no)"
check "case D: tree is clean afterwards" "" "$(git -C "$TMP/d" status --porcelain 2>/dev/null)"

# --- Case E: "hidden" means a component STARTING with a dot ------------------
# Not "a path containing a dot" - 'my.notes/README' and 'Attachments/a.b.png'
# are perfectly visible. A predicate that got this wrong would quietly refuse a
# large slice of ordinary vault content.
make_clash "$TMP/e" "my.notes/README"
check "case E really is a conflicted state" "1" "$(unmerged_count "$TMP/e")"
run_resolver "$TMP/e" "$TMP/e.log"; rc=$?
check "case E: a dot INSIDE a directory name is not hidden" "0" "$rc"
check "case E: it still gets its conflicted copy" "1" "$(copy_count "$TMP/e")"

# --- Case F: a dotfile nested under a visible folder is still hidden ---------
make_clash "$TMP/f" "notes/.secret.md"
check "case F really is a conflicted state" "1" "$(unmerged_count "$TMP/f")"
run_resolver "$TMP/f" "$TMP/f.log"; rc=$?
check "case F: a leading dot on the FILE is hidden too" "1" "$rc"
check "case F: no conflicted copy for it" "0" "$(copy_count "$TMP/f")"

# --- Case G: a mixed batch is all-or-nothing --------------------------------
# The resolver commits all of its work in ONE commit, so a half-resolved batch
# would leave the visible note resolved and the hidden one still unmerged, with
# nothing able to abort cleanly. It must touch nothing at all.
make_clash "$TMP/g" "note.md" ".agent-memory/notes.md"
check "case G really has two conflicted paths" "2" "$(unmerged_count "$TMP/g")"
head_before="$(git -C "$TMP/g" rev-parse HEAD)"
run_resolver "$TMP/g" "$TMP/g.log"; rc=$?
check "case G: the whole batch is refused" "1" "$rc"
check "case G: not even the VISIBLE note was copied" "0" "$(copy_count "$TMP/g")"
check "case G: nothing was committed" "$head_before" "$(git -C "$TMP/g" rev-parse HEAD)"
check "case G: both paths are still unmerged" "2" "$(unmerged_count "$TMP/g")"
git -C "$TMP/g" merge --abort >/dev/null 2>&1
check "case G: merge --abort recovers the whole tree" "" "$(git -C "$TMP/g" status --porcelain 2>/dev/null)"

# --- Case H: end-to-end, through the real daemon ----------------------------
# The unit cases prove the resolver's decision. This proves the decision
# survives the pipeline: merge fails -> resolver refuses -> reconcile_pass
# aborts the merge -> the remote never receives an invisible copy, and the log
# keeps saying so rather than going quiet.
git init -q --bare "$TMP/remote.git"
git init -q "$TMP/seed" && (
  cd "$TMP/seed"
  git config user.email t@t.invalid && git config user.name t
  mkdir -p .agent-memory
  echo "hello" > note.md
  echo "base" > .agent-memory/session.md
  git add -A && git commit -qm init
  git branch -M main && git remote add origin "$TMP/remote.git" && git push -q origin main
)
git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/main
git clone -q --branch main "$TMP/remote.git" "$TMP/agent"
git -C "$TMP/agent" config user.email a@a.invalid
git -C "$TMP/agent" config user.name agent

env VAULT_NAME=dotfolder \
    VAULT_REPO="$TMP/remote.git" \
    VAULT_DIR="$TMP/vault" \
    VAULT_BRANCH=main \
    VAULT_BRIDGE_INTERVAL=1 \
    XDG_CONFIG_HOME="$TMP/obstate" \
    bash "$BRIDGE" > "$TMP/h.log" 2>&1 &
BRIDGE_PID=$!

await 20 test -f "$TMP/vault/.agent-memory/session.md"
check "case H: bridge cloned the vault, dotfolder included" "0" "$?"
await 15 sh -c "! git -C '$TMP/vault' status --porcelain | grep -q ."

# Collide on the dotfolder file from both sides at once.
echo "device side" > "$TMP/vault/.agent-memory/session.md"
echo "agent side" > "$TMP/agent/.agent-memory/session.md"
git -C "$TMP/agent" add -A && git -C "$TMP/agent" commit -qm "agent clash"
agent_rev="$(git -C "$TMP/agent" rev-parse HEAD)"
git -C "$TMP/agent" push -q origin main

hidden_warned() { grep -q 'CONFLICT under a hidden path' "$TMP/h.log"; }
await 30 hidden_warned
check "case H: the daemon reports the hidden-path collision" "0" "$?"

# Give it several more passes to do the wrong thing if it were going to.
sleep 4
remote_copies="$(git -C "$TMP/remote.git" ls-tree -r --name-only main 2>/dev/null | grep -c 'conflicted copy' || true)"
check "case H: no conflicted copy ever reached the remote" "0" "$remote_copies"
check "case H: the vault tree is not left mid-merge" "" \
  "$(git -C "$TMP/vault" status --porcelain 2>/dev/null)"
check "case H: the stall keeps announcing itself rather than going quiet" "yes" \
  "$([ "$(grep -c 'CONFLICT under a hidden path' "$TMP/h.log")" -ge 2 ] && echo yes || echo "no ($(grep -c 'CONFLICT under a hidden path' "$TMP/h.log"))")"
# The no-force proof has to be structural here: the stall's own WARNING contains
# the word "force" (it promises never to force-push), so grepping the log for it
# would assert nothing. History being additive is the property that matters.
git -C "$TMP/remote.git" merge-base --is-ancestor "$agent_rev" main
check "case H: remote history is still additive (nothing was force-pushed over)" "0" "$?"
check "case H: both sides survive in git" "agent side" \
  "$(git -C "$TMP/remote.git" show "main:.agent-memory/session.md" 2>/dev/null)"
check "case H: and the device side is still in the vault working tree" "device side" \
  "$(cat "$TMP/vault/.agent-memory/session.md" 2>/dev/null)"

kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null; BRIDGE_PID=""

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

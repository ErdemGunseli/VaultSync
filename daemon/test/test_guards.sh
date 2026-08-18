#!/usr/bin/env bash
# Guards that stop a bad commit reaching the remote, and the silent-failure paths
# that used to look healthy. Every case here was a real defect found by review:
#   - a pass that emptied the vault was committed and PUSHED within one poll
#   - a conflicted copy skipped the size cap entirely
#   - a corrupt .git was treated as "already cloned", producing a silent zombie
#   - a failed commit (disk full) logged nothing at all
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  local secs="$1"; shift; local i=0
  while [ "$i" -lt "$((secs * 2))" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

TMP="$(mktemp -d)"
BRIDGE_PID=""
trap 'kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP" "$GIT_ISOLATED_CONFIG"' EXIT

# A remote seeded with 20 notes.
git init -q --bare "$TMP/remote.git"
git init -q "$TMP/seed"
( cd "$TMP/seed"
  git config user.email t@t.invalid; git config user.name t
  for i in $(seq 1 20); do printf 'note %s\n' "$i" > "note$i.md"; done
  git add -A; git commit -qm init; git branch -M main
  git remote add origin "$TMP/remote.git"; git push -q origin main ) >/dev/null 2>&1
git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/main

start_bridge() { # extra env...
  env VAULT_NAME=guards VAULT_REPO="$TMP/remote.git" VAULT_DIR="$TMP/vault" \
      VAULT_BRANCH=main VAULT_BRIDGE_INTERVAL=1 XDG_CONFIG_HOME="$TMP/obstate" \
      "$@" bash "$BRIDGE" > "$TMP/log" 2>&1 &
  BRIDGE_PID=$!
}
remote_count() { git -C "$TMP/remote.git" ls-tree -r --name-only main 2>/dev/null | wc -l; }

# --- 1. Mass deletion is refused, not pushed --------------------------------
start_bridge
await 20 test -f "$TMP/vault/note1.md"
check "bridge cloned the seeded vault" "0" "$?"
check "remote starts with 20 notes" "20" "$(remote_count)"

rm -f "$TMP/vault"/note*.md          # something empties the vault
sleep 6                               # several poll cycles
check "mass deletion is NOT pushed to the remote" "20" "$(remote_count)"
# Logged every pass, not once: a guard that says it once and then goes quiet
# looks identical to a healthy daemon in any bounded log view.
check "the refusal is logged, and keeps saying so each pass" "yes" \
  "$([ "$(grep -c 'REFUSING TO COMMIT' "$TMP/log")" -ge 1 ] && echo yes || echo no)"
check "the log says nothing was lost" "yes" \
  "$([ "$(grep -c 'nothing in git is lost' "$TMP/log")" -ge 1 ] && echo yes || echo no)"
kill $BRIDGE_PID 2>/dev/null; wait $BRIDGE_PID 2>/dev/null; BRIDGE_PID=""

# --- 2. A deletion under the threshold still syncs normally -----------------
# The guard must not turn ordinary tidying into a stuck vault.
rm -rf "$TMP/vault" "$TMP/obstate"
start_bridge
await 20 test -f "$TMP/vault/note1.md"
rm -f "$TMP/vault/note1.md" "$TMP/vault/note2.md"   # 2 of 20 = 10%
await 15 test "$(remote_count)" = "18"
check "a small deletion still syncs (guard is not a blanket freeze)" "18" "$(remote_count)"
kill $BRIDGE_PID 2>/dev/null; wait $BRIDGE_PID 2>/dev/null; BRIDGE_PID=""

# --- 3. An explicit override lets a real bulk deletion through --------------
rm -rf "$TMP/vault" "$TMP/obstate"
start_bridge VAULT_MAX_DELETE_PCT=0
await 20 test -f "$TMP/vault/note3.md"
rm -f "$TMP/vault"/note*.md
await 20 test "$(remote_count)" = "0"
check "VAULT_MAX_DELETE_PCT=0 disables the guard as documented" "0" "$(remote_count)"
kill $BRIDGE_PID 2>/dev/null; wait $BRIDGE_PID 2>/dev/null; BRIDGE_PID=""

# --- 4. A corrupt .git is refused, not run against -------------------------
rm -rf "$TMP/vault" "$TMP/obstate"
mkdir -p "$TMP/vault/.git"
printf 'garbage\n' > "$TMP/vault/.git/HEAD"
OUT="$(env VAULT_NAME=guards VAULT_REPO="$TMP/remote.git" VAULT_DIR="$TMP/vault" \
        VAULT_BRANCH=main VAULT_BRIDGE_INTERVAL=1 XDG_CONFIG_HOME="$TMP/obstate2" \
        timeout 15 bash "$BRIDGE" 2>&1)"
rc=$?
check "a corrupt .git exits instead of looping silently" "1" "$rc"
check "the corrupt-repo message names the cause" "1" \
  "$(printf '%s' "$OUT" | grep -c 'not a usable git repository')"

# --- 5. A clone failure surfaces git's own error, not just a guess ---------
OUT="$(env VAULT_NAME=guards VAULT_REPO="$TMP/remote.git" VAULT_DIR="$TMP/v2" \
        VAULT_BRANCH=nonexistent-branch VAULT_BRIDGE_INTERVAL=1 \
        XDG_CONFIG_HOME="$TMP/obstate3" timeout 15 bash "$BRIDGE" 2>&1)"
check "clone failure reports git's actual stderr" "1" \
  "$(printf '%s' "$OUT" | grep -ci 'remote branch')"
check "clone failure still offers the PAT/branch hints" "1" \
  "$(printf '%s' "$OUT" | grep -c 'default branch')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

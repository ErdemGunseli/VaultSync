#!/usr/bin/env bash
# Behavioural tests for the 5MB sync-cap guard: Obsidian Sync (Standard plan)
# refuses files over 5MB, so a file that big pushed via git would reach the
# repo but never reach a device - silent divergence. The bridge must refuse
# to commit an oversize file while still committing everything else, warn
# loudly, and repeat the warning each pass while the file remains staged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$HERE/../bridge.sh"
PASS=0; FAIL=0
# Isolate from the host's git config. NOT /dev/null: git >=2.43 parses a config
# path as a real file and errors "bad config line 1 in file /dev/null", which
# made every git-touching assertion in this suite fail for environmental
# reasons. An empty regular file is the portable isolation.
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

setup_remote() {
  local tmp="$1"
  git init -q --bare "$tmp/remote.git"
  git init -q "$tmp/seed" && (
    cd "$tmp/seed"
    git config user.email t@t.invalid && git config user.name t
    echo "hello" > note.md && git add -A && git commit -qm init
    git branch -M main && git remote add origin "$tmp/remote.git" && git push -q origin main
  )
  git -C "$tmp/remote.git" symbolic-ref HEAD refs/heads/main
}

# --- default cap (5MB): big file withheld, small file committed, warned ----
TMP="$(mktemp -d)"
trap 'kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP"' EXIT
setup_remote "$TMP"

env VAULT_NAME=cap \
    VAULT_REPO="$TMP/remote.git" \
    VAULT_DIR="$TMP/vault" \
    VAULT_BRANCH=main \
    VAULT_BRIDGE_INTERVAL=1 \
    XDG_CONFIG_HOME="$TMP/obstate" \
    bash "$BRIDGE" > "$TMP/log" 2>&1 &
BRIDGE_PID=$!

await 20 test -f "$TMP/vault/note.md"
check "bridge clones before the size-cap writes" "0" "$?"

echo "small and welcome" > "$TMP/vault/small.md"
head -c 6291456 /dev/zero > "$TMP/vault/big.bin"   # 6 MiB, over the 5MB default cap

small_landed() { git -C "$TMP/remote.git" show "main:small.md" >/dev/null 2>&1; }
await 15 small_landed
check "the small sibling file IS committed" "0" "$?"

big_landed() { git -C "$TMP/remote.git" show "main:big.bin" >/dev/null 2>&1; }
sleep 3   # give it several passes' worth of opportunity, in case the guard were absent
check "the 6MB file is NOT committed" "no" "$(big_landed && echo yes || echo no)"

check "a WARNING names the oversize file and its size" "yes" \
  "$(grep -q 'WARNING: big.bin exceeds sync cap' "$TMP/log" && echo yes || echo no)"

# The file stays in the working tree (uncommitted, not deleted) and the
# warning repeats each pass while it remains, per spec.
check "big.bin is still present on disk, just uncommitted" "1" "$([ -f "$TMP/vault/big.bin" ] && echo 1 || echo 0)"
warn_count="$(grep -c 'WARNING: big.bin exceeds sync cap' "$TMP/log")"
check "the warning repeats across passes, not just once" "yes" "$([ "$warn_count" -ge 2 ] && echo yes || echo "no ($warn_count)")"

kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null
rm -rf "$TMP"
trap - EXIT

# --- VAULT_MAX_FILE_MB=0 disables the guard: the big file IS committed -----
TMP="$(mktemp -d)"
trap 'kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP"' EXIT
setup_remote "$TMP"

env VAULT_NAME=nocap \
    VAULT_REPO="$TMP/remote.git" \
    VAULT_DIR="$TMP/vault" \
    VAULT_BRANCH=main \
    VAULT_BRIDGE_INTERVAL=1 \
    VAULT_MAX_FILE_MB=0 \
    XDG_CONFIG_HOME="$TMP/obstate" \
    bash "$BRIDGE" > "$TMP/log" 2>&1 &
BRIDGE_PID=$!

await 20 test -f "$TMP/vault/note.md"
check "bridge clones before the disabled-guard write" "0" "$?"

head -c 6291456 /dev/zero > "$TMP/vault/big.bin"
big_landed_nocap() { git -C "$TMP/remote.git" show "main:big.bin" >/dev/null 2>&1; }
await 15 big_landed_nocap
check "with VAULT_MAX_FILE_MB=0 the 6MB file IS committed" "0" "$?"
check "no size-cap warning is logged when the guard is disabled" "0" "$(grep -c 'exceeds sync cap' "$TMP/log")"

kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null
rm -rf "$TMP"
trap - EXIT

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

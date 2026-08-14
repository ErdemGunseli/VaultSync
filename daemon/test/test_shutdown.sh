#!/usr/bin/env bash
# End-to-end shutdown test: SIGTERM to the REAL entrypoint must take down the
# REAL bridge and its whole descendant tree (inotifywait included).
#
# This exists because the bug it guards against actually happened: the
# entrypoint's supervise() subshells died on SIGTERM without forwarding it, and
# an orphaned bridge kept committing and pushing after "shutting down" was
# logged. On a redeploy that is two daemons writing one vault repo. The proof
# of death here is behavioural: after the kill, a new file written into the
# vault must NOT be committed by anything.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

check() {
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1))
  else printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

await() {
  local secs="$1"; shift
  local i=0
  while [ "$i" -lt "$(( secs * 2 ))" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

TMP="$(mktemp -d)"
trap 'kill -9 $ENTRY_PID 2>/dev/null; pkill -9 -f "vault-bridge-shutdowntest" 2>/dev/null; rm -rf "$TMP"' EXIT

git init -q --bare "$TMP/remote.git"
git init -q "$TMP/seed" && cd "$TMP/seed"
git config user.email t@t.invalid && git config user.name t
echo hello > note.md && git add -A && git commit -qm init
git branch -M main && git remote add origin "$TMP/remote.git" && git push -q origin main
cd "$HERE"
git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/main

# Run the REAL entrypoint with the REAL bridge in plain-env single-vault mode.
# TMPDIR is namespaced so the EXIT trap's pkill can never touch anything else.
mkdir -p "$TMP/secrets" "$TMP/data"
env -i PATH="$PATH" HOME="$TMP" TMPDIR="$TMP" \
    SECRETS_DIR="$TMP/secrets" DATA_DIR="$TMP/data" \
    XDG_CONFIG_HOME="$TMP/data/ob-state" \
    BRIDGE_BIN="$HERE/../bridge.sh" \
    VAULT_NAME="shutdowntest" \
    VAULT_REPO="$TMP/remote.git" \
    VAULT_BRANCH=main \
    VAULT_POLL_ACTIVE=1 VAULT_POLL_IDLE=2 \
    bash "$HERE/../entrypoint.sh" > "$TMP/log" 2>&1 &
ENTRY_PID=$!

VAULT="$TMP/data/vaults/shutdowntest"
await 20 test -d "$VAULT/.git"
check "entrypoint brings up a real bridge (vault cloned)" "0" "$?"

# Prove the bridge is alive and writing before we kill anything.
echo "pre-kill" > "$VAULT/alive.md"
alive_committed() { git -C "$TMP/remote.git" show main:alive.md >/dev/null 2>&1; }
await 20 alive_committed
check "bridge is functioning before shutdown" "0" "$?"

# The kill. Plain TERM to the entrypoint - exactly what tini forwards.
kill -TERM "$ENTRY_PID" 2>/dev/null
await 15 sh -c "! kill -0 $ENTRY_PID 2>/dev/null"
check "entrypoint exits on SIGTERM" "0" "$?"

# The whole tree must be gone: no bridge, no inotifywait, nothing still
# watching this vault. Give stragglers a beat, then check by side effect AND
# by process table.
sleep 2
survivors="$(pgrep -f "vaults/shutdowntest" 2>/dev/null | grep -v "^$$\$" | wc -l)"
check "no process still references the vault after shutdown" "0" "$survivors"

# Behavioural proof of death: a post-kill edit must never be committed.
echo "post-kill" > "$VAULT/deadman.md" 2>/dev/null || true
sleep 6
dead_committed() { git -C "$TMP/remote.git" show main:deadman.md >/dev/null 2>&1; }
if dead_committed; then dm=1; else dm=0; fi
check "a post-shutdown edit is NOT committed (no orphaned writer)" "0" "$dm"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

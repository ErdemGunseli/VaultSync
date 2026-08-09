#!/usr/bin/env bash
# End-to-end test of the git half of the bridge, against real git repos.
#
# Runs the actual bridge.sh (no stubs, no mocks) in git-only mode - which is
# also the degradation path when Obsidian credentials are absent - and asserts
# that edits genuinely move in BOTH directions through a real remote.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$HERE/../bridge.sh"
PASS=0; FAIL=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

check() {
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1))
  else printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

# Wait until a command succeeds, up to N seconds. Returns 1 on timeout.
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
trap 'kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP"' EXIT

# A real remote, and a second clone standing in for "an agent pushing to GitHub".
git init -q --bare "$TMP/remote.git"
git init -q "$TMP/seed" && cd "$TMP/seed"
git config user.email t@t.invalid && git config user.name t
echo "hello" > note.md && git add -A && git commit -qm init
git branch -M main && git remote add origin "$TMP/remote.git" && git push -q origin main
cd "$HERE"

# The bare repo was created before any push, so its HEAD still points at the
# git default branch name. Point it at main so clones check out correctly.
git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/main
git clone -q --branch main "$TMP/remote.git" "$TMP/agent"
git -C "$TMP/agent" config user.email a@a.invalid
git -C "$TMP/agent" config user.name agent

# Run the real bridge. `ob` is either absent or unauthenticated here, so this
# also exercises the documented git-only degradation rather than crashing.
env VAULT_NAME=test \
    VAULT_REPO="$TMP/remote.git" \
    VAULT_DIR="$TMP/vault" \
    VAULT_BRANCH=main \
    VAULT_BRIDGE_INTERVAL=1 \
    XDG_CONFIG_HOME="$TMP/obstate" \
    bash "$BRIDGE" > "$TMP/log" 2>&1 &
BRIDGE_PID=$!

await 20 test -f "$TMP/vault/note.md"
check "bridge clones the vault from the remote" "0" "$?"

# --- Direction 1: a local vault edit reaches the remote ---------------------
# (this is the phone -> Obsidian Sync -> vault dir -> git path, minus Sync)
echo "written by a device" > "$TMP/vault/from-device.md"
remote_has() { git -C "$TMP/remote.git" show "main:from-device.md" >/dev/null 2>&1; }
await 20 remote_has
check "a new file in the vault is committed and pushed to the remote" "0" "$?"

# --- Direction 2: a remote (agent) commit reaches the vault ----------------
# The bridge just pushed, so this clone is behind; catch up first (an agent
# working against the repo would do the same).
git -C "$TMP/agent" pull -q --ff-only origin main
echo "written by an agent" > "$TMP/agent/from-agent.md"
git -C "$TMP/agent" add -A && git -C "$TMP/agent" commit -qm "agent edit"
git -C "$TMP/agent" push -q origin main
await 25 test -f "$TMP/vault/from-agent.md"
check "a commit pushed to the remote lands in the vault working tree" "0" "$?"
check "its content is intact" "written by an agent" "$(cat "$TMP/vault/from-agent.md" 2>/dev/null)"

# --- Never force-push, never rewrite: divergence is surfaced, not resolved --
before="$(git -C "$TMP/remote.git" rev-parse main)"
git -C "$TMP/vault" commit -q --allow-empty -m "local only" 2>/dev/null
git -C "$TMP/agent" pull -q --ff-only origin main
echo "conflicting" > "$TMP/agent/from-agent.md"
git -C "$TMP/agent" commit -qam "remote diverges" && git -C "$TMP/agent" push -q origin main
after_remote="$(git -C "$TMP/remote.git" rev-parse main)"
sleep 4
still="$(git -C "$TMP/remote.git" rev-parse main)"
check "remote advanced by the agent, not rewritten by the bridge" "$after_remote" "$still"
# Surfaced on every pass while the divergence stands - that is the intent, so
# assert "at least once", not an exact count tied to the poll interval.
nff="$(grep -c 'not fast-forward' "$TMP/log")"
check "bridge keeps surfacing the non-fast-forward instead of forcing" "yes" \
  "$([ "$nff" -ge 1 ] && echo yes || echo no)"
check "bridge never ran a force push" "0" "$(grep -c 'force' "$TMP/log")"

# Degradation path is announced, not silent.
check "git-only degradation is warned about" "1" "$(grep -c 'git-only mode' "$TMP/log")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

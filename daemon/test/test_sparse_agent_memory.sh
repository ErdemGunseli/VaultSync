#!/usr/bin/env bash
# Sparse policy changes only this worker's clean derived checkout. The real
# Git index/remote retain hidden metadata through add-A, fast-forward and merge.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRIDGE="${BRIDGE_UNDER_TEST:-$HERE/../bridge.sh}"
LAB="$(mktemp -d)"; LAB="$(cd "$LAB" && pwd -P)"
PID=""; PASS=0; FAIL=0
cleanup() { [ -z "$PID" ] || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }; rm -rf "$LAB"; }
trap cleanup EXIT
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); else printf 'FAIL - %s: expected %s got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
await() { local n=0; while [ "$n" -lt 50 ]; do "$@" >/dev/null 2>&1 && return; sleep .1; n=$((n+1)); done; return 1; }
export GIT_CONFIG_GLOBAL="$LAB/gitconfig" GIT_CONFIG_SYSTEM="$LAB/gitconfig"
: > "$LAB/gitconfig"
git init -q --bare "$LAB/remote.git"; git init -q "$LAB/seed"
git -C "$LAB/seed" config user.name fixture; git -C "$LAB/seed" config user.email fixture@example.invalid
mkdir -p "$LAB/seed/.agent-memory" "$LAB/seed/.obsidian"
printf 'retained hidden bookkeeping\n' > "$LAB/seed/.agent-memory/base.md"
printf 'visible device note\n' > "$LAB/seed/note.md"
printf '{"setting":true}\n' > "$LAB/seed/.obsidian/app.json"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm seed; git -C "$LAB/seed" branch -M main
git -C "$LAB/seed" remote add origin "$LAB/remote.git"; git -C "$LAB/seed" push -qu origin main
git -C "$LAB/remote.git" symbolic-ref HEAD refs/heads/main
start() {
  env VAULT_NAME=sparse VAULT_REPO="$LAB/remote.git" VAULT_DIR="$LAB/vault" \
    XDG_CONFIG_HOME="$LAB/state" VAULT_HEALTH_DIR="$LAB/health" \
    VAULT_EXCLUDE_AGENT_MEMORY=1 VAULT_BRIDGE_INTERVAL=.2 VAULT_HEARTBEAT_SECS=0 \
    bash "$BRIDGE" > "$LAB/log" 2>&1 & PID=$!
}
stop() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""; }
remote_has() { git -C "$LAB/remote.git" cat-file -e "main:$1"; }
start
await test -f "$LAB/vault/note.md" || true
check 'initial checkout does not materialize agent-only data' no "$([ -e "$LAB/vault/.agent-memory" ] && echo yes || echo no)"
check 'initial checkout preserves visible note' 'visible device note' "$(cat "$LAB/vault/note.md" 2>/dev/null)"
check 'initial checkout preserves Obsidian settings' yes "$([ -f "$LAB/vault/.obsidian/app.json" ] && echo yes || echo no)"
check 'hidden bookkeeping remains in the complete Git index' yes "$(git -C "$LAB/vault" ls-files --error-unmatch .agent-memory/base.md >/dev/null 2>&1 && echo yes || echo no)"
printf 'local note\n' > "$LAB/vault/local.md"
await remote_has local.md || true
check 'ordinary add-A never deletes sparse metadata from origin' yes "$(remote_has .agent-memory/base.md && echo yes || echo no)"
check 'visible local edits still deliver' yes "$(remote_has local.md && echo yes || echo no)"
git -C "$LAB/seed" pull -q --ff-only
printf 'new hidden metadata\n' > "$LAB/seed/.agent-memory/remote.md"
printf 'new device content\n' > "$LAB/seed/remote.md"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm remote; git -C "$LAB/seed" push -q
await test -f "$LAB/vault/remote.md" || true
check 'fast-forward downloads visible content' yes "$([ -f "$LAB/vault/remote.md" ] && echo yes || echo no)"
check 'fast-forward keeps bookkeeping out of checkout' no "$([ -e "$LAB/vault/.agent-memory" ] && echo yes || echo no)"
stop
# Divergence while the bridge is stopped, then a true merge on restart.
printf 'local diverged\n' > "$LAB/vault/diverged.md"
git -C "$LAB/vault" add -A; git -C "$LAB/vault" commit -qm local-divergence
printf 'more metadata\n' > "$LAB/seed/.agent-memory/diverged.md"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm metadata-divergence; git -C "$LAB/seed" push -q
start
await remote_has diverged.md || true
check 'divergent merge retains remote hidden bytes' 'more metadata' "$(git -C "$LAB/remote.git" show main:.agent-memory/diverged.md 2>/dev/null)"
check 'divergent merge retains local visible bytes' 'local diverged' "$(git -C "$LAB/remote.git" show main:diverged.md 2>/dev/null)"
check 'merge keeps excluded metadata absent from worktree' no "$([ -e "$LAB/vault/.agent-memory" ] && echo yes || echo no)"
stop
git -C "$LAB/vault" sparse-checkout disable
printf 'uncommitted owner bytes\n' > "$LAB/vault/.agent-memory/base.md"
printf 'untracked owner bytes\n' > "$LAB/vault/.agent-memory/untracked.md"
before="$(git -C "$LAB/remote.git" rev-parse main)"
start
await grep -q 'sparse exclusion refused' "$LAB/log" || true
check 'dirty tracked excluded data is retained byte-for-byte' 'uncommitted owner bytes' "$(cat "$LAB/vault/.agent-memory/base.md")"
check 'untracked excluded data is retained byte-for-byte' 'untracked owner bytes' "$(cat "$LAB/vault/.agent-memory/untracked.md")"
check 'refusal cannot publish an accidental deletion or owner edit' "$before" "$(git -C "$LAB/remote.git" rev-parse main)"
check 'refusal names the dirty/untracked condition' yes "$(grep -q 'dirty, untracked, or ignored' "$LAB/log" && echo yes || echo no)"
stop
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

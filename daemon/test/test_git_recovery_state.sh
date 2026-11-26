#!/usr/bin/env bash
# Real interrupted merge/index state. Startup must not turn conflict markers or
# an ENOSPC-lost index into an ordinary add-A commit, with or without sparse mode.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRIDGE="${BRIDGE_UNDER_TEST:-$HERE/../bridge.sh}"
LAB="$(mktemp -d)"; LAB="$(cd "$LAB" && pwd -P)"
PID=""; PASS=0; FAIL=0
cleanup() { [ -z "$PID" ] || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }; rm -rf "$LAB"; }
trap cleanup EXIT
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); else printf 'FAIL - %s: expected %s got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
await() { local n=0; while [ "$n" -lt 40 ]; do "$@" >/dev/null 2>&1 && return; sleep .1; n=$((n+1)); done; return 1; }
export GIT_CONFIG_GLOBAL="$LAB/gitconfig" GIT_CONFIG_SYSTEM="$LAB/gitconfig"
: > "$LAB/gitconfig"
git init -q --bare "$LAB/remote.git"; git init -q "$LAB/seed"
git -C "$LAB/seed" config user.name fixture; git -C "$LAB/seed" config user.email fixture@example.invalid
printf 'base\n' > "$LAB/seed/note.md"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm seed; git -C "$LAB/seed" branch -M main
git -C "$LAB/seed" remote add origin "$LAB/remote.git"; git -C "$LAB/seed" push -qu origin main
git -C "$LAB/remote.git" symbolic-ref HEAD refs/heads/main
mkdir "$LAB/bin"
cat > "$LAB/bin/ob" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = sync ]; then echo started >> "$RECOVERY_SYNC_STARTS"; exec sleep 600; fi
exit 0
STUB
chmod +x "$LAB/bin/ob"
for sparse in 0 1; do
  vault="$LAB/vault-$sparse"
  git clone -q "$LAB/remote.git" "$vault"
  git -C "$vault" config user.name fixture; git -C "$vault" config user.email fixture@example.invalid
  git -C "$vault" checkout -qb right
  printf 'right\n' > "$vault/note.md"; git -C "$vault" commit -qam right
  git -C "$vault" checkout -q main
  printf 'left\n' > "$vault/note.md"; git -C "$vault" commit -qam left
  git -C "$vault" merge right >/dev/null 2>&1 || true
  before_stages="$(git -C "$vault" ls-files -u)"
  before_hash="$(git hash-object "$vault/note.md")"
  before_remote="$(git -C "$LAB/remote.git" rev-parse main)"
  env PATH="$LAB/bin:$PATH" RECOVERY_SYNC_STARTS="$LAB/sync-$sparse" \
    VAULT_NAME="recovery$sparse" VAULT_REPO="$LAB/remote.git" VAULT_DIR="$vault" \
    VAULT_HEALTH_DIR="$LAB/health" XDG_CONFIG_HOME="$LAB/state" \
    VAULT_SYNC_REMOTE=fixture OBSIDIAN_AUTH_TOKEN=fixture VAULT_EXCLUDE_AGENT_MEMORY="$sparse" \
    VAULT_BRIDGE_INTERVAL=.2 VAULT_HEARTBEAT_SECS=0 bash "$BRIDGE" > "$LAB/log-$sparse" 2>&1 & PID=$!
  await grep -q git_operation_in_progress "$LAB/health/recovery$sparse.json" || true
  kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
  check "sparse=$sparse retains all three unmerged index stages" "$before_stages" "$(git -C "$vault" ls-files -u)"
  check "sparse=$sparse retains marker bytes without calling them resolved" "$before_hash" "$(git hash-object "$vault/note.md")"
  check "sparse=$sparse never pushes an interrupted merge" "$before_remote" "$(git -C "$LAB/remote.git" rev-parse main)"
  check "sparse=$sparse reports held operation state" yes "$(grep -q git_operation_in_progress "$LAB/health/recovery$sparse.json" 2>/dev/null && echo yes || echo no)"
  check "sparse=$sparse never starts native Sync over marker bytes" no "$([ -f "$LAB/sync-$sparse" ] && echo yes || echo no)"
done
for broken in missing empty; do
  vault="$LAB/index-$broken"; git clone -q "$LAB/remote.git" "$vault"
  if [ "$broken" = missing ]; then rm "$vault/.git/index"; else : > "$vault/.git/index"; fi
  before_remote="$(git -C "$LAB/remote.git" rev-parse main)"
  before_hash="$(git hash-object "$vault/note.md")"
  env VAULT_NAME="index$broken" VAULT_REPO="$LAB/remote.git" VAULT_DIR="$vault" \
    VAULT_HEALTH_DIR="$LAB/health" XDG_CONFIG_HOME="$LAB/state" VAULT_BRIDGE_INTERVAL=.2 \
    VAULT_HEARTBEAT_SECS=0 bash "$BRIDGE" > "$LAB/log-index-$broken" 2>&1 & PID=$!
  await grep -Eq 'git_index_incomplete|index_failed' "$LAB/health/index$broken.json" || true
  kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""
  check "$broken index cannot silently reconstruct and publish partial worktree" "$before_remote" "$(git -C "$LAB/remote.git" rev-parse main)"
  check "$broken index retains working bytes" "$before_hash" "$(git hash-object "$vault/note.md")"
  check "$broken index surfaces a static recovery reason" yes "$(grep -Eq 'git_index_incomplete|index_failed' "$LAB/health/index$broken.json" 2>/dev/null && echo yes || echo no)"
done
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

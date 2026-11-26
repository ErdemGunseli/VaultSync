#!/usr/bin/env bash
# Actual bare Git, synthetic note, and controllable process/storage boundaries.
# Never fills a host filesystem or touches a real vault/credential.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="${BRIDGE_UNDER_TEST:-$HERE/../bridge.sh}"
LAB="$(mktemp -d)"
LAB="$(cd "$LAB" && pwd -P)"
BRIDGE_PID=""; PASS=0; FAIL=0
cleanup() { [ -z "$BRIDGE_PID" ] || { kill "$BRIDGE_PID" 2>/dev/null || true; wait "$BRIDGE_PID" 2>/dev/null || true; }; if [ "${STORAGE_KEEP_LAB:-}" = 1 ]; then echo "fixture retained: $LAB"; else rm -rf "$LAB"; fi; }
trap cleanup EXIT
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); else printf 'FAIL - %s (expected %s, got %s)\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
await() { local n=0; while [ "$n" -lt 40 ]; do "$@" >/dev/null 2>&1 && return 0; sleep .1; n=$((n+1)); done; return 1; }
field() { sed -n 's/^ *"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\},\{0,1\}$/\1/p' "$LAB/health/storage.json" 2>/dev/null; }
field_is() { [ "$(field "$1")" = "$2" ]; }
stop() {
  local n=0
  kill "$BRIDGE_PID" 2>/dev/null || true
  while kill -0 "$BRIDGE_PID" 2>/dev/null && [ "$n" -lt 80 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$BRIDGE_PID" 2>/dev/null; then
    check 'shutdown completes within8seconds rather than resuming timed-read loop' stopped still_running
    kill -KILL "$BRIDGE_PID" 2>/dev/null || true
  fi
  wait "$BRIDGE_PID" 2>/dev/null || true; BRIDGE_PID=""
}
export GIT_CONFIG_GLOBAL="$LAB/gitconfig" GIT_CONFIG_SYSTEM="$LAB/gitconfig"
: > "$LAB/gitconfig"
REAL_GIT="$(command -v git)"; export REAL_GIT
mkdir -p "$LAB/bin" "$LAB/state"; export STORAGE_LAB="$LAB"
cat > "$LAB/bin/df" <<'STUB'
#!/usr/bin/env bash
read -r bytes inodes < "$STORAGE_LAB/capacity"
if [ "$1" = -Pi ]; then
  if [ -f "$STORAGE_LAB/bsd-df" ]; then
    printf 'Filesystem 512-blocks Used Available Capacity iused ifree %%iused Mounted on\nfixture 999999 1 999999 1%% 1 %s 1%% /fixture\n' "$inodes"
  else
    printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\nfixture 999999 1 %s 1%% /fixture\n' "$inodes"
  fi
else
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 9999999 1 %s 1%% /fixture\n' "$((bytes / 1024))"
fi
STUB
cat > "$LAB/bin/git" <<'STUB'
#!/usr/bin/env bash
op=""; for arg in "$@"; do case "$arg" in add|fetch|push) op="$arg"; break;; esac; done
if [ "$op" = add ] && [ -f "$STORAGE_LAB/fail-stage" ]; then echo 'fatal: No space left on device https://secret-token@invalid/' >&2; exit 73; fi
if [ "$op" = fetch ] && [ -f "$STORAGE_LAB/fail-fetch" ]; then echo 'fatal: authentication failed https://secret-token@invalid/' >&2; exit 74; fi
exec "$REAL_GIT" "$@"
STUB
cat > "$LAB/bin/ob" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = sync ]; then
  printf '%s\n' "$$" >> "$STORAGE_LAB/ob-starts"
  if [ -f "$STORAGE_LAB/ob-exit" ]; then echo 'Another sync instance is already running for this vault.'; exit 1; fi
  trap 'echo stopped >> "$STORAGE_LAB/ob-stops"; exit 0' TERM INT
  while true; do
    if [ -f "$STORAGE_LAB/ob-error" ]; then echo '[fixture] Sync error: storage unavailable'; else echo 'Fully synced'; fi
    sleep .2
  done
fi
exit 0
STUB
chmod +x "$LAB/bin/df" "$LAB/bin/git" "$LAB/bin/ob"
git init -q --bare "$LAB/remote.git"
git init -q "$LAB/seed"
git -C "$LAB/seed" config user.name fixture
git -C "$LAB/seed" config user.email fixture@example.invalid
printf 'seed\n' > "$LAB/seed/seed.md"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm seed
git -C "$LAB/seed" branch -M main
git -C "$LAB/seed" remote add origin "$LAB/remote.git"
git -C "$LAB/seed" push -q origin main
git -C "$LAB/remote.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/remote.git" "$LAB/vault"
capacity() { printf '%s %s\n' "$1" "$2" > "$LAB/capacity"; }
start() {
  env PATH="$LAB/bin:$PATH" VAULT_NAME=storage VAULT_REPO="$LAB/remote.git" \
    VAULT_DIR="$LAB/vault" VAULT_SYNC_REMOTE=fixture OBSIDIAN_AUTH_TOKEN=fixture \
    XDG_CONFIG_HOME="$LAB/state" VAULT_HEALTH_DIR="$LAB/health" \
    VAULT_BRIDGE_INTERVAL=.2 VAULT_HEARTBEAT_SECS=0 VAULT_OB_TIMEOUT=1 \
    "$@" bash "$BRIDGE" > "$LAB/log" 2>&1 &
  BRIDGE_PID=$!
}
capacity 0 99999
touch "$LAB/ob-exit"
start
await field_is storage_reason bytes || true
if [ "${STORAGE_TEST_CASE:-}" = red ]; then sleep 2; fi
check 'zero bytes publishes blocked health outside the vault' blocked "$(field status)"
check 'zero bytes never starts native Sync' no "$([ -f "$LAB/ob-starts" ] && echo yes || echo no)"
if [ "${STORAGE_TEST_CASE:-}" = red ]; then
  printf 'duplicate-instance restart attempts: %s\n' "$(grep -c 'Another sync instance' "$LAB/log" || true)"
  stop; printf '%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
rm "$LAB/ob-exit"
capacity 1073741824 0
await field_is storage_reason inodes || true
check 'zero inodes also blocks with ample bytes' inodes "$(field storage_reason)"
touch "$LAB/bsd-df"
sleep .4
check 'BSD inode layout reads ifree rather than available blocks' inodes "$(field storage_reason)"
rm "$LAB/bsd-df"
capacity 201326592 99999
sleep .5
check 'hysteresis refuses to restart at192MiB' blocked "$(field status)"
capacity 1073741824 99999
await field_is status healthy || true
check 'capacity recovery resumes the same process and native Sync' healthy "$(field status)"
check 'successful fetch has its own clock' yes "$([ "$(field last_fetch_success)" -gt 0 ] 2>/dev/null && echo yes || echo no)"
touch "$LAB/ob-error"
await field_is reason sync_failed || true
first_sync="$(field last_sync_success)"
sleep 1.3
check 'error chatter is not successful Sync progress' "$first_sync" "$(field last_sync_success)"
check 'native errors degrade current health before silence timeout' sync_failed "$(field reason)"
touch "$LAB/fail-stage"
head -c 219000 /dev/zero | tr '\0' A > "$LAB/vault/FinalMax.md"
note_hash="$(git hash-object "$LAB/vault/FinalMax.md")"
await field_is git_reason stage_failed || true
check 'git add failure is explicit and sanitized' stage_failed "$(field git_reason)"
check 'stage failure includes numeric return code' 73 "$(field last_git_rc)"
check 'the219KB note remains byte-identical after stage refusal' "$note_hash" "$(git hash-object "$LAB/vault/FinalMax.md")"
check 'stderr tokens never appear in daemon log' no "$(grep -q secret-token "$LAB/log" && echo yes || echo no)"
rm "$LAB/fail-stage" "$LAB/ob-error"
await bash -c '"$REAL_GIT" -C "$STORAGE_LAB/remote.git" cat-file -e main:FinalMax.md' || true
remote_hash="$(git -C "$LAB/remote.git" rev-parse main:FinalMax.md 2>/dev/null || true)"
check 'recovery delivers the original219KB note to real bare Git' "$note_hash" "$remote_hash"
await field_is status healthy || true
fetch_clock="$(field last_fetch_success)"
touch "$LAB/fail-fetch"
await field_is git_reason fetch_failed || true
check 'fetch failure cannot appear healthy' degraded "$(field status)"
check 'failed fetch never advances success clock' "$fetch_clock" "$(field last_fetch_success)"
rm "$LAB/fail-fetch"
await field_is status healthy || true
check 'fetch recovery needs no daemon restart' healthy "$(field status)"
capacity 0 99999
await field_is status blocked || true
await test -f "$LAB/ob-stops" || true
check 'periodic storage guard gracefully stops the owned Sync child' yes "$([ -f "$LAB/ob-stops" ] && echo yes || echo no)"
starts="$(wc -l < "$LAB/ob-starts" | tr -d ' ')"
sleep 1
check 'blocked storage cannot create a restart loop' "$starts" "$(wc -l < "$LAB/ob-starts" | tr -d ' ')"
capacity 1073741824 99999
await field_is status healthy || true
check 'native Sync automatically restarts after storage recovery' healthy "$(field status)"
check 'health artifacts stay outside tracked content' no "$(git -C "$LAB/remote.git" ls-tree -r --name-only main | grep -q health && echo yes || echo no)"
touch "$LAB/ob-error"
await field_is reason sync_failed || true
stop
# A new live process is not a successful native sync. Old success clocks are
# retained for diagnosis, but the previous run's success cannot bless this run.
old_success="$(field last_sync_success)"; old_push="$(field last_push_success)"
start
await field_is reason sync_failed || true
check 'configured Sync emitting only errors cannot appear healthy' degraded "$(field status)"
check 'new native session requires its own completed cycle' sync_failed "$(field reason)"
check 'restart retains the last real native success timestamp' "$old_success" "$(field last_sync_success)"
check 'restart retains the last successful Git push timestamp' "$old_push" "$(field last_push_success)"
stop
# The cache process is an independently tested boundary (its real fake-HTTP
# tests run in run.sh). Here prove the bridge calls it before a full-disk wait,
# at bounded cadence, and owns its lifecycle without signaling other processes.
cat > "$LAB/bin/node" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STORAGE_LAB/cache-argv"
echo called >> "$STORAGE_LAB/cache-calls"
previous=""; for arg in "$@"; do [ "$previous" != --cursor ] || printf '%s\n' "$arg" >> "$STORAGE_LAB/cache-cursors"; previous="$arg"; done
if [ -f "$STORAGE_LAB/cache-hang" ]; then
  trap 'echo stopped > "$STORAGE_LAB/cache-stopped"; exit 0' TERM INT
  while true; do sleep .2; done
fi
printf '1073741824 99999\n' > "$STORAGE_LAB/capacity"
if [ -f "$STORAGE_LAB/cache-overflow" ]; then
  printf '{"status":"incomplete","nextCursor":9007199254740992,"removedBytes":0}\n'
else
  printf '{"status":"complete","reason":"targets_met","removedBytes":1048576,"removedObjects":1,"nextCursor":17}\n'
fi
STUB
chmod +x "$LAB/bin/node"
rm "$LAB/ob-error"
capacity 0 99999
start VAULT_LFS_CACHE_BUDGET_BYTES=536870912
await field_is status healthy || true
check 'configured cache recovery runs before blocked startup wait' healthy "$(field status)"
sleep .5
check 'cache maintenance is bounded by its own cadence' 1 "$(wc -l < "$LAB/cache-calls" | tr -d ' ')"
check 'cache hook uses explicit reviewed apply mode' yes "$(grep -qx -- --apply "$LAB/cache-argv" && echo yes || echo no)"
check 'cache hook retains the512MiB budget' yes "$(grep -qx 536870912 "$LAB/cache-argv" && echo yes || echo no)"
check 'safe numeric cache cursor is retained in the receipt' 17 "$(field cache_cursor)"
stop
touch "$LAB/cache-hang"
start VAULT_LFS_CACHE_BUDGET_BYTES=536870912
await bash -c '[ "$(wc -l < "$STORAGE_LAB/cache-calls")" -ge 2 ]' || true
stop
check 'shutdown gracefully signals only its owned cache child' yes "$([ -f "$LAB/cache-stopped" ] && echo yes || echo no)"
check 'next native worker run resumes count-only cache traversal' 17 "$(tail -1 "$LAB/cache-cursors")"
rm "$LAB/cache-hang"
touch "$LAB/cache-overflow"
start VAULT_LFS_CACHE_BUDGET_BYTES=536870912
await field_is status healthy || true
await field_is cache_cursor 0 || true
check 'unsafe cache cursor is refused and resets to zero' 0 "$(field cache_cursor)"
stop
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

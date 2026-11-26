#!/usr/bin/env bash
# =============================================================================
# vault-bridge - Obsidian Sync <-> git reconciler for ONE vault.
# =============================================================================
# Launched by entrypoint.sh with this vault's env already sourced.
#
#   devices  --Obsidian Sync-->  ob (headless)  -->  VAULT_DIR  --git commit/push-->  remote
#   remote   --git pull-->  VAULT_DIR  -->  ob (headless)  --Obsidian Sync-->  devices
#
# DESIGN LAWS:
#   - git is the source of truth; the bridge is REQUIRED for seconds-delay
#     cross-device sync (Obsidian Sync has no webhook).
#   - Conflict policy: MATCH OBSIDIAN SYNC, never regress below it, never lose
#     data. Sync's own default auto-merges concurrent edits; so does the bridge:
#     device-vs-device conflicts stay Sync's job (its default merge strategy),
#     and git-side divergence is resolved by a real merge. A same-region
#     collision that git cannot merge becomes an Obsidian-style
#     "Note (conflicted copy <timestamp>).md" committed INTO the vault - it
#     surfaces on every device, inside Obsidian, exactly where Sync's own
#     conflicts appear. A collision under a HIDDEN path (any dotfolder or
#     dotfile, .obsidian/ included) cannot surface that way, so it takes the
#     loud path instead: no copy, merge aborted, WARNING. Never force-push; git
#     history keeps every side of every conflict, so nothing is ever lost.
#   - Refuse rather than corrupt: a file over the Sync cap is never committed, and
#     a pass that would delete most of the vault is refused outright (see
#     guard_mass_deletion) - git keeps everything, but a vault-emptying commit
#     would otherwise reach every device within one poll. VAULT_COMPRESS_IMAGES
#     is the one opt-in relaxation of the cap, and it never relaxes the refusal
#     itself - see compress_to_fit.
#   - Fail-soft: unset VAULT_REPO idles; missing/unauthenticated ob degrades to
#     git-only with a WARNING rather than crash-looping. Missing `inotifywait`
#     degrades to interval-only polling with a WARNING, same spirit.
#   - NOTHING may block on a prompt. Every `ob` call redirects stdin from
#     /dev/null so a missing credential fails fast instead of hanging forever.
#
# RECONCILE LOOP SHAPE:
#   One function, reconcile_pass(), does the actual pull/conflict-check/commit/
#   push work. It is fed by exactly two triggers into the SAME single-threaded
#   loop (never two reconcile passes concurrently - see main_loop below):
#     - event-driven: an inotifywait watch on VAULT_DIR (excluding .git/) wakes
#       the loop within ~1-2s of a local edit, after a short debounce so a burst
#       of writes (Obsidian saving on every keystroke) becomes one commit.
#     - periodic: a poll on a timeout, adaptive - fast while there is recent
#       local or remote activity, backing off toward an idle rate otherwise.
#   Both feed reconcile_pass() from the same loop iteration, so there is only
#   ever one reconcile in flight.
#
# ENV (see secrets.example/vault-planning.env):
#   VAULT_NAME                        logical name (log prefix, sync state key)
#   VAULT_REPO                        git URL incl. push auth (unset => idle)
#   VAULT_DIR                         working tree (default /data/vaults/<name>)
#   VAULT_BRANCH                      branch (default main)
#   VAULT_BRIDGE_INTERVAL             LEGACY: if set, pins BOTH the active and
#                                     idle remote-poll rate to this fixed value
#                                     (disables the adaptive backoff below).
#                                     Local-edit detection via inotify is
#                                     unaffected either way.
#   VAULT_POLL_ACTIVE                 remote-poll interval, seconds, while
#                                     there was local/remote activity within
#                                     VAULT_ACTIVE_WINDOW (default 2)
#   VAULT_POLL_IDLE                   remote-poll interval, seconds, once
#                                     activity has been quiet that long
#                                     (default 30)
#   VAULT_ACTIVE_WINDOW               seconds of recent activity that count as
#                                     "active" before backing off (default 300)
#   VAULT_MAX_FILE_MB                 files staged above this size are NOT
#                                     committed (Obsidian Sync Standard refuses
#                                     files over 5MB, so pushing one via git
#                                     would never reach devices). 0 disables.
#                                     (default 5)
#   VAULT_COMPRESS_IMAGES             OFF by default. When truthy, an image
#                                     ALREADY over VAULT_MAX_FILE_MB is
#                                     re-encoded in place to try to fit under
#                                     it, instead of being refused outright.
#                                     Only jpg/jpeg/png/webp, never anything
#                                     under the cap, never an LFS-tracked path,
#                                     and every re-encode is logged with its
#                                     before/after size. The refusal above is
#                                     still the floor: a file compression cannot
#                                     shrink enough is withheld exactly as
#                                     before. This is the ONLY place the daemon
#                                     rewrites a file's contents, and the
#                                     re-encode is lossy and irreversible -
#                                     hence opt-in.
#   VAULT_MAX_DELETE_PCT              a pass deleting at least this % of tracked
#                                     files is REFUSED, not committed (default
#                                     50; 0 disables). Guards against anything
#                                     that empties the working tree being
#                                     propagated to every device.
#   VAULT_MIN_DELETE_FLOOR            deletions below this count are never
#                                     refused, whatever the percentage
#                                     (default 10) - ordinary tidying in a small
#                                     vault must not trip the guard.
#   VAULT_DELETE_GRACE_SECS           a held deletion proceeds after this long if
#                                     still present (default 600). The guard
#                                     delays a catastrophe; it must never strand
#                                     an owner who meant it.
#   VAULT_OB_TIMEOUT                  seconds bounding each `ob` call (default
#                                     300 - generous enough for a large vault's
#                                     first link, which happens once). A stall would otherwise hang the
#                                     bridge before the reconcile loop, and the
#                                     supervisor only restarts a child that EXITS.
#   VAULT_OB_SILENCE_WARN             seconds of total `ob` silence after which
#                                     the heartbeat warns that device sync may
#                                     be dead despite the process being alive
#                                     (default 5400; 0 disables). ob narrates in
#                                     bursts, so this sits well above the gap.
#   VAULT_HEARTBEAT_SECS              seconds between heartbeat log lines
#                                     (default 900; 0 disables). A successful
#                                     pass is otherwise silent, so this is how
#                                     git-level liveness is confirmed from logs.
#   VAULT_SYNC_REMOTE                 Obsidian Sync remote vault name or id
#   VAULT_SYNC_ENCRYPTION_PASSWORD    E2E encryption password (REQUIRED if the
#                                     remote vault is encrypted - omitting it
#                                     makes `ob sync-setup` prompt, which fails
#                                     headless)
#   VAULT_SYNC_CONFIGS                comma list for `ob sync-config --configs`
#                                     (which .obsidian/ categories Obsidian Sync
#                                     carries to devices). DEFAULTS TO ALL EIGHT
#                                     - see SYNC_CONFIGS_DEFAULT below. Set it
#                                     to a narrower list to carry less, or to
#                                     the empty string to disable config syncing
#                                     entirely.
#   VAULT_DEVICE_NAME                 device label in Sync version history
#   OBSIDIAN_AUTH_TOKEN               PREFERRED auth: `ob` reads this env var
#                                     directly, so no login call and no MFA.
#   OBSIDIAN_EMAIL / OBSIDIAN_PASSWORD / OBSIDIAN_MFA   fallback interactive-less login
#   GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL  commit identity
# =============================================================================
set -u

NAME="${VAULT_NAME:-vault}"
VAULT_DIR="${VAULT_DIR:-/data/vaults/$NAME}"
VAULT_REPO="${VAULT_REPO:-}"
VAULT_BRANCH="${VAULT_BRANCH:-main}"
SYNC_REMOTE="${VAULT_SYNC_REMOTE:-}"
SYNC_ENC_PW="${VAULT_SYNC_ENCRYPTION_PASSWORD:-}"
# Two transports move a bridged vault and only one of them is selective.
# git <-> VAULT_DIR carries every tracked byte, .obsidian/ included. Obsidian
# Sync moves VAULT_DIR <-> devices and carries ONLY the config categories its
# stored per-vault config names - and `ob sync-setup` writes no such key at all,
# which the sync engine reads as `new Set(undefined || [])`: an EMPTY set, i.e.
# config syncing fully off (obsidian-headless 0.0.14 cli.js prints exactly
# "none (config syncing disabled)" for that state). So a vault whose .obsidian/
# tree is complete in git and on disk still lands on every device with zero
# plugins, zero themes and zero hotkeys, and nothing in either log says why.
# That cost the owner a day.
#
# This daemon exists to bridge a vault whose .obsidian/ is versioned in git.
# Carrying the notes but not the configuration that renders them is the wrong
# default for that job, so the default here is ALL EIGHT categories `ob`
# accepts. The list is pinned literally rather than discovered, because an
# invalid member makes `sync-config` exit non-zero and refuse the whole call
# (cli.js Vr() throws on the first unknown name), which would take the conflict
# strategy down with it. Verified against `ob sync-config --help` on 0.0.14; the
# Dockerfile pins that version, so re-check this list when bumping it.
SYNC_CONFIGS_DEFAULT="app,appearance,appearance-data,hotkey,core-plugin,core-plugin-data,community-plugin,community-plugin-data"
# `-` not `:-`: an operator who writes VAULT_SYNC_CONFIGS= in an env file means
# "carry no config", and that must not silently become the full default.
SYNC_CONFIGS="${VAULT_SYNC_CONFIGS-$SYNC_CONFIGS_DEFAULT}"
# Reported in the heartbeat so the choice is answerable from logs alone, which
# is precisely what was missing. Set by apply_sync_config.
SYNC_CONFIGS_STATE="unset"
DEVICE_NAME="${VAULT_DEVICE_NAME:-vault-bridge-$NAME}"
GIT_NAME="${GIT_AUTHOR_NAME:-vault-bridge}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-vault-bridge@localhost}"
OB_PID=""
SHUTDOWN_REQUESTED=0
PAUSE_PID=""

# Adaptive remote polling. A legacy VAULT_BRIDGE_INTERVAL pins both rates to
# one fixed value, reproducing the old fixed-15s (or test-overridden) loop.
POLL_ACTIVE="${VAULT_POLL_ACTIVE:-2}"
POLL_IDLE="${VAULT_POLL_IDLE:-30}"
ACTIVE_WINDOW="${VAULT_ACTIVE_WINDOW:-300}"
LEGACY_INTERVAL=""
if [ -n "${VAULT_BRIDGE_INTERVAL:-}" ]; then
  LEGACY_INTERVAL="$VAULT_BRIDGE_INTERVAL"
  POLL_ACTIVE="$LEGACY_INTERVAL"
  POLL_IDLE="$LEGACY_INTERVAL"
fi

# 5MB sync cap: Obsidian Sync (Standard plan) refuses files over this size, so
# committing one via git would reach the repo but never reach a phone/laptop -
# silent divergence discovered only when someone wonders why a file "isn't
# syncing". 0 disables the guard entirely.
MAX_FILE_MB="${VAULT_MAX_FILE_MB:-5}"

log() { printf '[vault-bridge:%s] %s\n' "$NAME" "$*" >&2; }

# The headless client's lock-acquire handler calls EVERY filesystem error
# "Another sync instance" (including ENOSPC). Check capacity before asking it
# to write. Hysteresis prevents sibling vaults sharing a disk from oscillating
# between starting and stopping at the same reserve boundary. Nothing here
# deletes files, unlocks a vault, or resets its history.
STORAGE_MIN_BYTES="${VAULT_STORAGE_MIN_BYTES:-134217728}"
STORAGE_RESUME_BYTES="${VAULT_STORAGE_RESUME_BYTES:-268435456}"
STORAGE_MIN_INODES="${VAULT_STORAGE_MIN_INODES:-1024}"
STORAGE_RESUME_INODES="${VAULT_STORAGE_RESUME_INODES:-2048}"
for storage_number in "$STORAGE_MIN_BYTES" "$STORAGE_RESUME_BYTES" "$STORAGE_MIN_INODES" "$STORAGE_RESUME_INODES"; do
  case "$storage_number" in ''|*[!0-9]*) log 'FATAL: storage reserves must be unsigned integers'; exit 1;; esac
done
if [ "$STORAGE_RESUME_BYTES" -lt "$STORAGE_MIN_BYTES" ] || [ "$STORAGE_RESUME_INODES" -lt "$STORAGE_MIN_INODES" ]; then
  log 'FATAL: storage recovery reserves must be at least the blocking reserves'; exit 1
fi
STORAGE_BLOCKED=0; STORAGE_REASON=unchecked; STORAGE_BYTES=0; STORAGE_INODES=0
GIT_STATE=pending; GIT_REASON=not_checked; LAST_GIT_RC=0
LAST_FETCH_SUCCESS=0; LAST_PUSH_SUCCESS=0; LAST_RECONCILE_SUCCESS=0
SYNC_MODE=git-only; SYNC_STATE=disabled; OB_STARTED_AT=0; OB_GENERATION=0; OB_RUN_ID=none
[ -z "$SYNC_REMOTE" ] || { SYNC_MODE=configured; SYNC_STATE=not_ready; }
HEALTH_KEY="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9_-' '_')"
HEALTH_DIR="${VAULT_HEALTH_DIR:-$(cd /tmp && pwd -P)/vaultsync-health}"
# A health receipt must remain writable when /data fills and cannot enter the
# vault. Refuse a symlink anywhere in its path, including an existing leaf.
case "$HEALTH_DIR" in /*) ;; *) log 'FATAL: VAULT_HEALTH_DIR must be absolute'; exit 1;; esac
case "$HEALTH_DIR/" in */../*|*/./*|//*|/|/tmp/|/private/tmp/|/data/) log 'FATAL: health directory must be a dedicated literal path'; exit 1;; esac
case "$HEALTH_DIR/" in "$VAULT_DIR/"*|"${XDG_CONFIG_HOME:-/data/ob-state}/"*) log 'FATAL: health directory must be outside vault and Sync state'; exit 1;; esac
health_parent="$HEALTH_DIR"
while [ "$health_parent" != / ]; do
  [ ! -L "$health_parent" ] || { log 'FATAL: health directory has a symlink component'; exit 1; }
  health_parent="$(dirname "$health_parent")"
done
if ! (umask 077; mkdir -p "$HEALTH_DIR") || [ ! -O "$HEALTH_DIR" ]; then
  log 'FATAL: health directory is not writable and owned by this worker'; exit 1
fi
chmod 700 "$HEALTH_DIR" || exit 1
HEALTH_FILE="$HEALTH_DIR/$HEALTH_KEY.json"
OB_ACTIVITY_FILE="$HEALTH_DIR/$HEALTH_KEY.sync-progress"
OB_SUCCESS_FILE="$HEALTH_DIR/$HEALTH_KEY.sync-success"
OB_STATUS_FILE="$HEALTH_DIR/$HEALTH_KEY.sync-status"
GIT_ERROR_FILE="$HEALTH_DIR/.$HEALTH_KEY.git-error-$$"
for health_path in "$HEALTH_FILE" "$OB_ACTIVITY_FILE" "$OB_SUCCESS_FILE" "$OB_STATUS_FILE" "$GIT_ERROR_FILE"; do
  [ ! -L "$health_path" ] || { log 'FATAL: health artifact is a symlink'; exit 1; }
done
(umask 077; : > "$GIT_ERROR_FILE") || { log 'FATAL: cannot create private Git diagnostic scratch'; exit 1; }
# Read only our numeric clock fields, never source/eval a previous receipt.
health_clock() {
  local value
  value="$(sed -n 's/^  "'"$1"'": \([0-9][0-9]*\),\{0,1\}$/\1/p' "$HEALTH_FILE" 2>/dev/null | head -1)"
  printf '%s' "${value:-0}"
}
LAST_FETCH_SUCCESS="$(health_clock last_fetch_success)"
LAST_PUSH_SUCCESS="$(health_clock last_push_success)"
LAST_RECONCILE_SUCCESS="$(health_clock last_git_reconcile_success)"
sync_clock() {
  local value=0 ignored
  [ ! -f "$1" ] || read -r value ignored < "$1"
  case "$value" in ''|*[!0-9]*) value=0;; esac
  printf '%s' "$value"
}
sync_marker() {
  local tmp
  tmp="$(umask 077; mktemp "$HEALTH_DIR/.$HEALTH_KEY.sync.XXXXXX")" || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f "$tmp" "$1"; then rm -f "$tmp"; return 1; fi
}
health_write() {
  local status=degraded reason="$GIT_REASON" tmp now progress synced sync_state="$SYNC_STATE" event_run="" event_state="" head remote_head
  now="$(date +%s)"; progress="$(sync_clock "$OB_ACTIVITY_FILE")"; synced="$(sync_clock "$OB_SUCCESS_FILE")"
  [ ! -f "$OB_STATUS_FILE" ] || read -r event_run event_state < "$OB_STATUS_FILE"
  if [ "$SYNC_MODE" = configured ] && [ "$SYNC_STATE" = starting ] && [ "$event_run" = "$OB_RUN_ID" ]; then
    case "$event_state" in ready|error) sync_state="$event_state";; esac
  fi
  if [ "$SYNC_MODE" = configured ] && ! owned_ob_running; then sync_state=not_ready; fi
  if [ "$STORAGE_BLOCKED" -eq 1 ]; then status=blocked; reason="storage_$STORAGE_REASON"
  elif [ "$GIT_STATE" = ok ]; then
    if [ "$SYNC_MODE" = git-only ] || [ "$sync_state" = ready ]; then status=healthy; reason=ok
    elif [ "$sync_state" = error ]; then reason=sync_failed
    else reason=sync_not_ready; fi
  fi
  if [ "$SYNC_MODE" = configured ] && [ "$sync_state" = ready ] && [ "${OB_SILENCE_WARN:-5400}" -gt 0 ] && [ $((now-progress)) -ge "${OB_SILENCE_WARN:-5400}" ]; then
    [ "$status" = blocked ] || { status=degraded; reason=sync_no_progress; }; sync_state=stalled
  fi
  head="$(git -C "$VAULT_DIR" rev-parse HEAD 2>/dev/null || true)"
  remote_head="$(git -C "$VAULT_DIR" rev-parse "refs/remotes/origin/$VAULT_BRANCH" 2>/dev/null || true)"
  case "$head" in *[!0-9a-f]*) head="";; esac
  case "$remote_head" in *[!0-9a-f]*) remote_head="";; esac
  tmp="$(umask 077; mktemp "$HEALTH_DIR/.$HEALTH_KEY.XXXXXX")" || { log 'WARNING: health receipt cannot be written'; return 1; }
  if ! {
    printf '{\n  "schema": 1,\n  "status": "%s",\n  "reason": "%s",\n' "$status" "$reason"
    printf '  "updated_at": %s,\n  "storage_state": "%s",\n  "storage_reason": "%s",\n' "$now" "$([ "$STORAGE_BLOCKED" -eq 1 ] && echo blocked || echo ready)" "$STORAGE_REASON"
    printf '  "available_bytes": %s,\n  "free_inodes": %s,\n' "$STORAGE_BYTES" "$STORAGE_INODES"
    printf '  "cache_cursor": %s,\n' "$LFS_CACHE_CURSOR"
    printf '  "sync_mode": "%s",\n  "sync_state": "%s",\n' "$SYNC_MODE" "$sync_state"
    printf '  "git_state": "%s",\n  "git_reason": "%s",\n  "last_git_rc": %s,\n' "$GIT_STATE" "$GIT_REASON" "$LAST_GIT_RC"
    printf '  "head": "%s",\n  "remote_head": "%s",\n' "$head" "$remote_head"
    printf '  "last_fetch_success": %s,\n  "last_push_success": %s,\n  "last_git_reconcile_success": %s,\n' "$LAST_FETCH_SUCCESS" "$LAST_PUSH_SUCCESS" "$LAST_RECONCILE_SUCCESS"
    printf '  "last_sync_progress": %s,\n  "last_sync_success": %s\n}\n' "$progress" "$synced"
  } > "$tmp" || ! mv -f "$tmp" "$HEALTH_FILE"; then
    rm -f "$tmp"; log 'WARNING: health receipt cannot be written'; return 1
  fi
}
storage_sample() {
  local path="$1" bytes inodes
  while [ ! -e "$path" ] && [ "$path" != / ]; do path="$(dirname "$path")"; done
  bytes="$(LC_ALL=C df -Pk "$path" 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="Available"||$i=="Avail") col=i} NR==2&&col {printf "%.0f",$col*1024}')"
  inodes="$(LC_ALL=C df -Pi "$path" 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="IFree"||$i=="IAvail"||$i=="ifree") col=i} NR==2&&col {printf "%.0f",$col}')"
  case "$bytes:$inodes" in *[!0-9:]*|:*|*:) return 1;; esac
  [ "$bytes" -ge "$STORAGE_BYTES" ] || STORAGE_BYTES="$bytes"
  [ "$inodes" -ge "$STORAGE_INODES" ] || STORAGE_INODES="$inodes"
}
storage_check() {
  local old="$STORAGE_BLOCKED:$STORAGE_REASON" min_bytes="$STORAGE_MIN_BYTES" min_inodes="$STORAGE_MIN_INODES"
  STORAGE_BYTES=9223372036854775807; STORAGE_INODES=9223372036854775807
  [ "$STORAGE_BLOCKED" -eq 0 ] || { min_bytes="$STORAGE_RESUME_BYTES"; min_inodes="$STORAGE_RESUME_INODES"; }
  if ! storage_sample "$VAULT_DIR" || ! storage_sample "${XDG_CONFIG_HOME:-/data/ob-state}"; then
    STORAGE_BLOCKED=1; STORAGE_REASON=probe_failed; STORAGE_BYTES=0; STORAGE_INODES=0
  elif [ "$STORAGE_BYTES" -lt "$min_bytes" ]; then STORAGE_BLOCKED=1; STORAGE_REASON=bytes
  elif [ "$STORAGE_INODES" -lt "$min_inodes" ]; then STORAGE_BLOCKED=1; STORAGE_REASON=inodes
  else STORAGE_BLOCKED=0; STORAGE_REASON=ok; fi
  if [ "$old" != "$STORAGE_BLOCKED:$STORAGE_REASON" ]; then
    if [ "$STORAGE_BLOCKED" -eq 1 ]; then
      log "STORAGE BLOCKED: reason=$STORAGE_REASON available_bytes=$STORAGE_BYTES free_inodes=$STORAGE_INODES; Sync and Git writes paused, no files removed."
    else log "storage recovered: available_bytes=$STORAGE_BYTES free_inodes=$STORAGE_INODES; resuming retained vault state."; fi
  fi
  [ "$STORAGE_BLOCKED" -eq 0 ]
}
# jobs -pr is this shell's own child table. A stale/reused numeric PID never
# authorizes a signal to a process belonging to another worker or vault.
owned_ob_running() { [ -n "$OB_PID" ] && jobs -pr | grep -Fxq "$OB_PID"; }
stop_owned_ob() {
  local n=0
  if owned_ob_running; then
    kill -TERM "$OB_PID" 2>/dev/null || true
    while owned_ob_running && [ "$n" -lt 25 ]; do sleep .2; n=$((n+1)); done
    if owned_ob_running; then SYNC_STATE=stop_pending; log 'WARNING: owned Sync child has not finished graceful shutdown'; return 1; fi
  fi
  [ -z "$OB_PID" ] || wait "$OB_PID" 2>/dev/null || true
  OB_PID=""; [ "$SYNC_MODE" != configured ] || SYNC_STATE=stopped
}
storage_wait() {
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  while ! storage_check; do
    stop_owned_ob || true
    health_write || true
    cache_maintenance
    storage_check && break
    bridge_pause "$POLL_IDLE"
  done
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  health_write || true
}
# wait is interruptible; a foreground sleep otherwise delays a requested stop
# until the entire idle interval has elapsed.
bridge_pause() {
  sleep "$1" & PAUSE_PID=$!
  wait "$PAUSE_PID" 2>/dev/null || true
  if [ "$SHUTDOWN_REQUESTED" -ne 0 ]; then
    kill -TERM "$PAUSE_PID" 2>/dev/null || true
    wait "$PAUSE_PID" 2>/dev/null || true
    PAUSE_PID=""; exit 0
  fi
  PAUSE_PID=""
}
git_failure() {
  GIT_STATE=failed; GIT_REASON="${1}_failed"; LAST_GIT_RC="$2"
  log "WARNING: git $1 failed rc=$2; retained local state; retrying after preflight."
  if grep -Eqi 'no space left|ENOSPC|disk full' "$GIT_ERROR_FILE" 2>/dev/null; then
    STORAGE_BLOCKED=1; STORAGE_REASON=write_enospc
    log 'STORAGE BLOCKED: Git reported ENOSPC; no lock removal or file deletion attempted.'
    stop_owned_ob || true
  fi
  health_write || true
}

# A redeploy can interrupt a merge after Git has written conflict stages but
# before our resolver finishes. Never let the ordinary add-A path certify those
# marker bytes as a resolution, or treat a lost index as intentional deletions.
# Leave every byte/stage in place for explicit recovery, without abort/reset.
GIT_OPERATION_WARNED=""
GIT_INTENT_FILE="$VAULT_DIR/.git/vaultsync-mutation-intent"
GIT_INTENT_RECEIPT=""
GIT_MUTATION_HELD=0
# A failed checkout can leave partial files without MERGE_HEAD. A durable intent
# is created and fsynced before any worktree mutation; only this process's exact
# untouched marker can be removed after a verified clean completion/abort.
git_intent_io() {
  node - "$VAULT_DIR/.git" "$1" "${2:-}" <<'NODE'
const fs=require('node:fs'),crypto=require('node:crypto'),path=require('node:path');
const [directory,action,value]=process.argv.slice(2),c=fs.constants;
let dir,fd;
const identity=(s,body)=>[s.dev,s.ino,s.mode,s.nlink,s.size,s.mtimeNs,s.ctimeNs,crypto.createHash('sha256').update(body).digest('hex')].join(':');
try {
  if(!fs.lstatSync(directory).isDirectory()||fs.lstatSync(directory).isSymbolicLink())throw Error();
  dir=fs.openSync(directory,c.O_RDONLY|c.O_DIRECTORY|c.O_NOFOLLOW);
  const file=process.platform==='linux'?`/proc/self/fd/${dir}/vaultsync-mutation-intent`:path.join(directory,'vaultsync-mutation-intent');
  if(action==='create-intent'){
    if(!/^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value))throw Error();
    fd=fs.openSync(file,c.O_WRONLY|c.O_CREAT|c.O_EXCL|c.O_NOFOLLOW,0o600);
    const body=Buffer.from(JSON.stringify({schema:1,owner:crypto.randomBytes(24).toString('hex'),head:value})+'\n');
    fs.writeFileSync(fd,body);fs.fsyncSync(fd);fs.fsyncSync(dir);
    process.stdout.write(identity(fs.fstatSync(fd,{bigint:true}),body));
  }else if(action==='clear-intent'){
    fd=fs.openSync(file,c.O_RDONLY|c.O_NOFOLLOW);
    const before=fs.fstatSync(fd,{bigint:true});
    if(!before.isFile()||before.nlink!==1n||before.size>4096n)throw Error();
    const body=fs.readFileSync(fd),current=fs.lstatSync(file,{bigint:true});
    if(identity(before,body)!==value||identity(current,body)!==value)throw Error();
    fs.unlinkSync(file);fs.fsyncSync(dir);
  }else throw Error();
}catch{process.exitCode=1;}finally{if(fd!==undefined)fs.closeSync(fd);if(dir!==undefined)fs.closeSync(dir);}
NODE
}
git_intent_begin() {
  local head receipt rc
  head="$(git -C "$VAULT_DIR" rev-parse HEAD 2>"$GIT_ERROR_FILE")" || return 1
  receipt="$(git_intent_io create-intent "$head" 2>"$GIT_ERROR_FILE")"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$receipt" ]; then
    GIT_MUTATION_HELD=1; GIT_STATE=held; GIT_REASON=mutation_intent_unavailable; LAST_GIT_RC="$rc"
    log 'WARNING: Git worktree mutation held: durable intent could not be created; no mutation attempted.'
    health_write || true; return 1
  fi
  GIT_INTENT_RECEIPT="$receipt"
}
git_intent_finish() {
  local dirty rc
  git_worktree_ready 0 owned || return 1
  dirty="$(git -C "$VAULT_DIR" status --porcelain 2>"$GIT_ERROR_FILE")"; rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$dirty" ] || [ -z "$GIT_INTENT_RECEIPT" ] ||
     ! git_intent_io clear-intent "$GIT_INTENT_RECEIPT" 2>"$GIT_ERROR_FILE"; then
    GIT_MUTATION_HELD=1; GIT_STATE=held; GIT_REASON=worktree_mutation_incomplete; LAST_GIT_RC="$rc"
    log 'WARNING: Git worktree mutation incomplete; Native remains stopped and intent retained for explicit recovery.'
    health_write || true; return 1
  fi
  GIT_INTENT_RECEIPT=""; GIT_MUTATION_HELD=0
}
git_worktree_ready() {
  local operation reason="" unmerged rc head_paths
  if [ "$GIT_MUTATION_HELD" -eq 1 ] ||
     { { [ -e "$GIT_INTENT_FILE" ] || [ -L "$GIT_INTENT_FILE" ]; } &&
       { [ "${2:-}" != owned ] || [ -z "$GIT_INTENT_RECEIPT" ]; }; }; then
    reason=worktree_mutation_incomplete
  fi
  for operation in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    [ ! -e "$VAULT_DIR/.git/$operation" ] || reason=git_operation_in_progress
  done
  unmerged="$(git -C "$VAULT_DIR" ls-files --unmerged 2>"$GIT_ERROR_FILE")"; rc=$?
  if [ "$rc" -ne 0 ]; then git_failure index "$rc"; return 1; fi
  [ -z "$unmerged" ] || reason=git_operation_in_progress
  if [ -z "$reason" ] && [ "${1:-0}" != 1 ]; then
    git -C "$VAULT_DIR" ls-files --error-unmatch '*' >/dev/null 2>"$GIT_ERROR_FILE"; rc=$?
    if [ "$rc" -eq 1 ]; then
      head_paths="$(git -C "$VAULT_DIR" ls-tree -r --name-only HEAD 2>"$GIT_ERROR_FILE")"; rc=$?
      if [ "$rc" -ne 0 ]; then git_failure index "$rc"; return 1; fi
      [ -z "$head_paths" ] || reason=git_index_incomplete
    elif [ "$rc" -ne 0 ]; then git_failure index "$rc"; return 1; fi
  fi
  if [ -n "$reason" ]; then
    GIT_STATE=held; GIT_REASON="$reason"; LAST_GIT_RC=0
    if [ "$GIT_OPERATION_WARNED" != "$reason" ]; then
      log "WARNING: $reason; Sync and Git writes paused, index and working bytes retained for explicit recovery."
      GIT_OPERATION_WARNED="$reason"
    fi
    health_write || true; return 1
  fi
  GIT_OPERATION_WARNED=""
}

# Worker-only footprint policy. Keep the full Git index/history while omitting
# clean derived files that Obsidian cannot use. Full remains the default and
# preserves the older single-directory opt-in. Never replace a custom policy.
EXCLUDE_AGENT_MEMORY="${VAULT_EXCLUDE_AGENT_MEMORY:-0}"
CHECKOUT_PROFILE="${VAULT_CHECKOUT_PROFILE:-full}"
CHECKOUT_MODE=full
LEGACY_SPARSE_PATTERNS=$'/*\n!/.agent-memory/'
# Git ignore/attribute files are needed at every depth, including hidden
# parents. Explicit directory exclusions keep similarly named directories
# from accidentally including archives; .obsidian retains its full subtree.
OBSIDIAN_SPARSE_PATTERNS=$'/*\n!**/.*\n**/.gitignore\n**/.gitattributes\n!**/.gitignore/\n!**/.gitattributes/\n/.obsidian/**'
case "$CHECKOUT_PROFILE" in
  obsidian) CHECKOUT_MODE=obsidian;;
  full) case "$EXCLUDE_AGENT_MEMORY" in 1|true|yes) CHECKOUT_MODE=agent-memory;; esac;;
  *) log 'FATAL: VAULT_CHECKOUT_PROFILE must be full or obsidian'; exit 1;;
esac
worker_checkout_includes() {
  case "$CHECKOUT_MODE" in
    full) return 0;;
    agent-memory) case "$1" in .agent-memory|.agent-memory/*) return 1;; *) return 0;; esac;;
  esac
  case "$1" in .obsidian|.obsidian/*) return 0;; esac
  case "${1##*/}" in .gitignore|.gitattributes) return 0;; esac
  case "/$1" in */.*) return 1;; *) return 0;; esac
}
worker_sparse_clean() {
  local initial="$1" record relative listing dirty=0
  listing="$(umask 077; mktemp "$HEALTH_DIR/.$HEALTH_KEY.sparse.XXXXXX")" || return 1
  if [ "$initial" = 1 ]; then
    # No-checkout clones intentionally have no index yet. Inspect unexpected
    # filesystem entries directly instead of mistaking tracked absences for edits.
    if ! (cd "$VAULT_DIR" && find . -path ./.git -prune -o -print0) > "$listing" 2>"$GIT_ERROR_FILE"; then
      rm -f "$listing"; return 1
    fi
    while IFS= read -r -d '' record; do
      relative="${record#./}"
      [ "$relative" = . ] && continue
      if ! worker_checkout_includes "$relative"; then dirty=1; break; fi
    done < "$listing"
  else
    # Porcelain -z plus --no-renames yields one exact path per NUL record,
    # including spaces, newlines and ignored/untracked excluded bytes.
    if ! git -C "$VAULT_DIR" status --porcelain=v1 -z --no-renames --ignored --untracked-files=all > "$listing" 2>"$GIT_ERROR_FILE"; then
      rm -f "$listing"; return 1
    fi
    while IFS= read -r -d '' record; do
      if ! worker_checkout_includes "${record:3}"; then dirty=1; break; fi
    done < "$listing"
  fi
  rm -f "$listing"
  [ "$dirty" -eq 0 ]
}
worker_sparse_excluded_materialized() {
  local listing record found=1
  listing="$(umask 077; mktemp "$HEALTH_DIR/.$HEALTH_KEY.sparse.XXXXXX")" || return 2
  if ! (cd "$VAULT_DIR" && find . -path ./.git -prune -o ! -type d -print0) > "$listing" 2>"$GIT_ERROR_FILE"; then
    rm -f "$listing"; return 2
  fi
  while IFS= read -r -d '' record; do
    if ! worker_checkout_includes "${record#./}"; then found=0; break; fi
  done < "$listing"
  rm -f "$listing"; return "$found"
}
configure_worker_sparse() {
  [ "$CHECKOUT_MODE" != full ] || [ "${1:-0}" = 1 ] || return 0
  local patterns dirty rc wanted="$LEGACY_SPARSE_PATTERNS"
  [ "$CHECKOUT_MODE" != obsidian ] || wanted="$OBSIDIAN_SPARSE_PATTERNS"
  if [ "$CHECKOUT_MODE" != full ] && ! worker_sparse_clean "${1:-0}"; then
    log 'FATAL: worker sparse exclusion refused: excluded paths have dirty, untracked, or ignored files; all retained.'
    GIT_STATE=failed; GIT_REASON=sparse_dirty; health_write || true; return 1
  fi
  if [ "$CHECKOUT_MODE" != full ] && [ "$(git -C "$VAULT_DIR" config --bool core.sparseCheckout 2>/dev/null || true)" = true ]; then
    patterns="$(git -C "$VAULT_DIR" rev-parse --git-path info/sparse-checkout)"
    case "$patterns" in /*) ;; *) patterns="$VAULT_DIR/$patterns";; esac
    patterns="$(cat "$patterns" 2>/dev/null)"
    if [ "$(git -C "$VAULT_DIR" config --bool core.sparseCheckoutCone 2>/dev/null || true)" = true ] ||
       { [ "$patterns" != "$wanted" ] && { [ "$CHECKOUT_MODE" != obsidian ] || [ "$patterns" != "$LEGACY_SPARSE_PATTERNS" ]; }; }; then
      log 'FATAL: worker sparse exclusion refused: a different sparse policy already exists.'
      GIT_STATE=failed; GIT_REASON=sparse_policy_conflict; health_write || true; return 1
    fi
    if [ "$patterns" = "$wanted" ] && [ "${1:-0}" != 1 ]; then
      # A stable existing sparse checkout needs no worktree mutation. Keep
      # legitimate uncommitted visible saves available to normal reconciliation.
      worker_sparse_excluded_materialized; rc=$?
      if [ "$rc" -eq 1 ]; then
        log "worker checkout profile=$CHECKOUT_MODE already configured; no checkout mutation needed."
        return 0
      elif [ "$rc" -ne 0 ]; then return 1; fi
    fi
  fi
  if owned_ob_running && ! stop_owned_ob; then return 1; fi
  if [ "${1:-0}" != 1 ]; then
    dirty="$(git -C "$VAULT_DIR" status --porcelain 2>"$GIT_ERROR_FILE")"; rc=$?
    if [ "$rc" -ne 0 ] || [ -n "$dirty" ]; then
      GIT_STATE=held; GIT_REASON=checkout_requires_clean_tree; LAST_GIT_RC="$rc"
      log 'WARNING: checkout policy change deferred: a clean index and worktree are required; all local bytes retained.'
      health_write || true; return 1
    fi
  fi
  git_intent_begin || return 1
  if [ "$CHECKOUT_MODE" != full ] && ! printf '%s\n' "$wanted" | git -C "$VAULT_DIR" sparse-checkout set --no-cone --stdin >/dev/null 2>"$GIT_ERROR_FILE"; then
    log 'FATAL: worker sparse exclusion failed; no history or source deletion attempted.'
    GIT_STATE=failed; GIT_REASON=sparse_failed; health_write || true; return 1
  fi
  if [ "${1:-0}" = 1 ]; then
    # sparse-checkout set configures the pattern but an initial --no-checkout
    # clone can still have an EMPTY index. Populate it through the sparse-aware
    # read-tree before add-A can ever interpret missing entries as deletions.
    if ! git -C "$VAULT_DIR" read-tree -mu HEAD 2>"$GIT_ERROR_FILE" ||
       ! git -C "$VAULT_DIR" diff --cached --quiet HEAD; then
      log 'FATAL: initial sparse checkout/index verification failed; reconciliation refused.'
      GIT_STATE=failed; GIT_REASON=sparse_initial_checkout_failed; health_write || true; return 1
    fi
  fi
  git_intent_finish || return 1
  log "worker checkout profile=$CHECKOUT_MODE; index, history, origin and visible Sync files retained."
}

# Optional bounded verified LFS-cache maintenance. The helper only evicts
# remotely confirmed derived cache objects, never tracked/working-tree files.
# Run before the storage wait so a full disk can recover without a restart.
LFS_CACHE_BUDGET="${VAULT_LFS_CACHE_BUDGET_BYTES:-}"
LFS_CACHE_INTERVAL="${VAULT_LFS_CACHE_INTERVAL:-300}"
LFS_CACHE_AFTER=0
LFS_CACHE_CURSOR="$(health_clock cache_cursor)"
cache_cursor() {
  case "$1" in ''|*[!0-9]*) printf 0; return;; esac
  if [ "${#1}" -gt 16 ] || [ "$1" -gt 9007199254740991 ]; then printf 0; else printf '%s' "$1"; fi
}
LFS_CACHE_CURSOR="$(cache_cursor "$LFS_CACHE_CURSOR")"
CACHE_PID=""
CACHE_RECEIPT="$HEALTH_DIR/.$HEALTH_KEY.cache-receipt-$$"
[ ! -L "$CACHE_RECEIPT" ] || { log 'FATAL: cache receipt is a symlink'; exit 1; }
CACHE_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cache-maintenance.mjs"
cache_maintenance() {
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  [ -n "$LFS_CACHE_BUDGET" ] && [ -d "$VAULT_DIR/.git" ] || return 0
  local now result rc
  now="$(date +%s)"
  [ "$now" -ge "$LFS_CACHE_AFTER" ] || return 0
  LFS_CACHE_AFTER=$((now+LFS_CACHE_INTERVAL))
  (umask 077; : > "$CACHE_RECEIPT") || { log 'WARNING: cache receipt unavailable'; return 1; }
  node "$CACHE_HELPER" --repo-dir "$VAULT_DIR" --budget-bytes "$LFS_CACHE_BUDGET" --target-free-bytes "$STORAGE_RESUME_BYTES" --max-bytes 2147483648 --max-objects 1024 --max-seconds 120 --cursor "$LFS_CACHE_CURSOR" --apply >"$CACHE_RECEIPT" 2>/dev/null &
  CACHE_PID=$!
  wait "$CACHE_PID"; rc=$?
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  CACHE_PID=""
  result="$(cat "$CACHE_RECEIPT")"; rm -f "$CACHE_RECEIPT"
  LFS_CACHE_CURSOR="$(cache_cursor "$(printf '%s' "$result" | sed -n 's/.*"nextCursor"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*[,}].*/\1/p')")"
  # Only the helper's structured, sanitized receipt is logged, never stderr
  # (Git credential helpers and HTTP errors may contain authenticated URLs).
  log "LFS cache maintenance rc=$rc receipt=$result"
}
if [ -n "$LFS_CACHE_BUDGET" ]; then
  case "$LFS_CACHE_BUDGET:$LFS_CACHE_INTERVAL" in *[!0-9:]*|:*|*:) log 'FATAL: LFS cache budget/interval must be unsigned integers'; exit 1;; esac
  [ "$LFS_CACHE_INTERVAL" -gt 0 ] || { log 'FATAL: LFS cache interval must be positive'; exit 1; }
  command -v node >/dev/null 2>&1 && [ -f "$CACHE_HELPER" ] || { log 'FATAL: configured LFS cache maintenance helper is unavailable'; exit 1; }
fi

# `ob` must never inherit a TTY or a readable stdin: a prompt in a background
# worker hangs forever and is invisible. Fail fast instead. Every ob call is also
# time-bounded. Without this a network stall in sync-setup hung the
# bridge before it ever reached the reconcile loop - and supervise() restarts a
# vault only when its child EXITS, so a hang meant that vault silently stopped
# syncing for the life of the container with nothing in the log to say so.
OB_TIMEOUT="${VAULT_OB_TIMEOUT:-300}"
ob_q() { timeout "$OB_TIMEOUT" ob "$@" </dev/null >/dev/null 2>&1; }
ob_v() { timeout "$OB_TIMEOUT" ob "$@" </dev/null; }

INOTIFY_PID=""
FIFO=""

cleanup() {
  stop_owned_ob || true
  if [ -n "$CACHE_PID" ] && jobs -pr | grep -Fxq "$CACHE_PID"; then
    kill -TERM "$CACHE_PID" 2>/dev/null || true
    wait "$CACHE_PID" 2>/dev/null || true
  fi
  if [ -n "$PAUSE_PID" ] && jobs -pr | grep -Fxq "$PAUSE_PID"; then
    kill -TERM "$PAUSE_PID" 2>/dev/null || true
    wait "$PAUSE_PID" 2>/dev/null || true
  fi
  if [ -n "$INOTIFY_PID" ] && kill -0 "$INOTIFY_PID" 2>/dev/null; then
    kill "$INOTIFY_PID" 2>/dev/null || true
    wait "$INOTIFY_PID" 2>/dev/null || true
  fi
  if [ "$GIT_STATE" = ok ] || [ "$GIT_STATE" = pending ]; then GIT_STATE=stopped; GIT_REASON=worker_stopped; fi
  health_write || true
  exec 3<&- 2>/dev/null || true
  [ -n "$FIFO" ] && rm -f "$FIFO" 2>/dev/null || true
  rm -f "$GIT_ERROR_FILE" 2>/dev/null || true
  rm -f "$CACHE_RECEIPT" 2>/dev/null || true
}
# EXIT covers normal/error returns and the shutdown flag checks below. Cleanup
# remains idempotent, but never runs inside a timed read's signal handler.
trap cleanup EXIT
# A timed read's deadline can interrupt a long signal trap in Bash, abandoning
# cleanup before its final exit and resuming the main loop. Set only a flag in
# the handler. Exit AFTER read/wait returns; EXIT then owns the full cleanup.
trap 'SHUTDOWN_REQUESTED=1' INT TERM

# --- 0. Unconfigured => idle without error -----------------------------------
if [ -z "$VAULT_REPO" ]; then
  log "VAULT_REPO unset - bridge idle. Configure it to enable. No-op."
  while true; do bridge_pause 3600; done
fi

# A tokenless https VAULT_REPO + a global GIT_TOKEN compose into an
# authenticated URL here. This keeps the per-vault secret files free of
# credentials (they carry only identifiers - repo URL, Sync remote name), so
# one PAT set once as a service env var covers every vault, and rotating it is
# one dashboard edit instead of one per vault.
if [ -n "${GIT_TOKEN:-}" ]; then
  case "$VAULT_REPO" in
    https://*@*) ;;  # URL already carries a credential - it wins
    https://*)   VAULT_REPO="https://${GIT_TOKEN}@${VAULT_REPO#https://}" ;;
  esac
fi

# Configured-but-fake is worse than unconfigured: a REPLACE_ME placeholder that
# reaches git or ob produces a confusing auth error instead of the actual
# problem. Fail closed and name the fix (config-minimalism: half-configured
# must never half-work).
if printf '%s' "${VAULT_REPO} ${GIT_TOKEN:-} ${SYNC_ENC_PW} ${OBSIDIAN_AUTH_TOKEN:-}" \
   | grep -q 'REPLACE_ME'; then
  log "FATAL: a config value for this vault is still the REPLACE_ME placeholder."
  log "       Fill the real value in the env group. Adding a vault has three parts:"
  log "       its VAULT_* keys, extending GIT_TOKEN to the new repo (fine-grained"
  log "       PATs enumerate repos explicitly), and its E2E password if encrypted."
  exit 1
fi

command -v git >/dev/null 2>&1 || { log "FATAL: git not installed"; exit 1; }
# Includes initial clone/checkout: do not wait until a partial checkout has
# already consumed the last writable bytes on the persistent volume.
cache_maintenance
storage_wait
HAVE_LFS=0
if command -v git-lfs >/dev/null 2>&1; then
  HAVE_LFS=1
  git lfs install --skip-repo >/dev/null 2>&1 || log "WARNING: git-lfs install failed (media may not sync)"
fi

# --- 1. Ensure the vault clone exists ----------------------------------------
# Presence of a .git DIRECTORY is not proof of a usable repository: a clone
# interrupted mid-write leaves one behind, and treating it as "already cloned"
# produced a silent zombie - every later git command failed while the only log
# line was a benign-looking "push failed" once per poll, forever. Ask git.
# A persistent volume can carry files owned by a different UID than this process
# (restore, migration, a future non-root USER). Git then refuses the repo for
# "dubious ownership" - benign, and NOT corruption. Declare it safe before the
# validity check so the FATAL below cannot fire on a perfectly healthy repo.
git config --global --add safe.directory "$VAULT_DIR" >/dev/null 2>&1 || true
if [ -d "$VAULT_DIR/.git" ] && ! git -C "$VAULT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  log "FATAL: $VAULT_DIR/.git exists but is not a usable git repository"
  log "       (an interrupted clone leaves this behind). Refusing to run against it:"
  log "       every operation would fail silently. Delete the directory to re-clone."
  exit 1
fi
INITIAL_CHECKOUT=0
if [ ! -d "$VAULT_DIR/.git" ]; then
  log "cloning vault -> $VAULT_DIR (branch $VAULT_BRANCH)"
  if ! mkdir -p "$(dirname "$VAULT_DIR")" 2>/dev/null; then
    log "FATAL: cannot create $(dirname "$VAULT_DIR") - is the data disk mounted and writable?"
    exit 1
  fi
  # Capture git's own stderr instead of discarding it. The generic guess-list
  # below is useful, but "Remote branch main not found" or "No space left on
  # device" is the actual answer, and it was being thrown away.
  clone_args=(--branch "$VAULT_BRANCH" --no-checkout)
  INITIAL_CHECKOUT=1
  clone_err="$(git clone "${clone_args[@]}" "$VAULT_REPO" "$VAULT_DIR" 2>&1 >/dev/null)" || {
    # Never echo the URL: it carries the token. Strip anything before '@'.
    log "FATAL: clone failed. Not retrying blindly. git said:"
    printf '%s\n' "$clone_err" | sed 's#https://[^@]*@#https://***@#g' | while IFS= read -r l; do
      log "       $l"
    done
    log "       Common causes: VAULT_BRANCH does not match the repo's default branch;"
    log "       the repo is empty (no initial commit); GIT_TOKEN does not cover this"
    log "       repo (fine-grained PATs list repositories explicitly, so a newly"
    log "       added vault is never covered automatically); or the disk is full."
    exit 1
  }
fi
storage_wait
git_worktree_ready "$INITIAL_CHECKOUT" || exit 1
configure_worker_sparse "$INITIAL_CHECKOUT" || exit 1
git_worktree_ready || exit 1
cache_maintenance
# A vault that declares LFS filters but has no git-lfs binary does not fail — git
# commits the raw pointer files as if they were the media. That is silent data
# corruption discovered only when someone opens a broken image, so refuse instead.
if [ "$HAVE_LFS" -eq 0 ]; then
  # NB: test grep's output, not find's exit status - find succeeds when it
  # matches nothing, which would turn "no LFS anywhere" into a false FATAL.
  lfs_decl="$(find "$VAULT_DIR" -name .gitattributes -not -path '*/.git/*' \
    -exec grep -l 'filter=lfs' {} + 2>/dev/null || true)"
  if [ -n "$lfs_decl" ]; then
    log "FATAL: vault declares Git LFS filters but git-lfs is not installed."
    log "       Committing now would write pointer files in place of media. Refusing."
    exit 1
  fi
  log "WARNING: git-lfs not found. Vault declares no LFS filters, so continuing."
fi

git -C "$VAULT_DIR" config user.name  "$GIT_NAME"  2>/dev/null || true
git -C "$VAULT_DIR" config user.email "$GIT_EMAIL" 2>/dev/null || true
# Keep origin current when the credential rotates.
git -C "$VAULT_DIR" remote set-url origin "$VAULT_REPO" 2>/dev/null || true

# --- 2. Obsidian Sync (optional; degrades to git-only) -----------------------
ensure_ob_auth() {
  # `ob` reads OBSIDIAN_AUTH_TOKEN from the environment directly (verified
  # against obsidian-headless 0.0.14), so when it is set there is no login step
  # and MFA never applies. This is the preferred path for an unattended worker.
  if [ -n "${OBSIDIAN_AUTH_TOKEN:-}" ]; then
    log "auth: using OBSIDIAN_AUTH_TOKEN from environment"
    return 0
  fi
  if ob_q sync-list-remote; then
    log "auth: existing session in \$XDG_CONFIG_HOME/obsidian-headless"
    return 0
  fi
  if [ -n "${OBSIDIAN_EMAIL:-}" ] && [ -n "${OBSIDIAN_PASSWORD:-}" ]; then
    log "auth: attempting non-interactive login for $OBSIDIAN_EMAIL"
    set -- login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD"
    [ -n "${OBSIDIAN_MFA:-}" ] && set -- "$@" --mfa "$OBSIDIAN_MFA"
    if ob_q "$@"; then
      log "auth: login OK"
      return 0
    fi
    log "WARNING: login failed. If this account has MFA, a static password cannot work -"
    log "         log in once elsewhere and set OBSIDIAN_AUTH_TOKEN instead."
  fi
  log "WARNING: no Obsidian credentials (set OBSIDIAN_AUTH_TOKEN, or EMAIL+PASSWORD)."
  return 1
}

# Push the conflict strategy, mode and config categories at the stored per-vault
# sync config. Split out of the link step deliberately: `sync-config` is
# idempotent and `ensure_ob_setup` returns early for an ALREADY-linked vault, so
# leaving this inline meant a settings change could only ever reach a vault that
# had never been linked. Every existing bridge would keep its original settings
# forever, with a redeploy looking like it had applied them. It runs on both
# paths now, so a redeploy heals a vault linked under an older default.
apply_sync_config() {
  # Conflict policy is a design law: match Sync's own end-to-end behaviour.
  # Sync's default strategy auto-merges concurrent device edits; forcing
  # `conflict` here would make the bridged experience WORSE than plain Sync
  # (conflict litter a Sync-only user never sees). Git history is the safety
  # net that makes merge safe: every pre-merge state is a commit.
  set -- sync-config --path "$VAULT_DIR" --conflict-strategy merge --mode bidirectional
  # Always passed, empty included. Omitting the flag is NOT "use a default" -
  # cli.js gates on `configs !== undefined`, so an omitted flag leaves whatever
  # is already stored untouched, which is the bug this whole block exists to
  # close. An explicit empty string is `ob`'s own documented "clear".
  set -- "$@" --configs "$SYNC_CONFIGS"
  if [ -n "$SYNC_CONFIGS" ]; then
    log "sync-config: asking Obsidian Sync to carry config categories: $SYNC_CONFIGS"
  else
    log "sync-config: VAULT_SYNC_CONFIGS is empty - Obsidian Sync will carry NO .obsidian/ config."
    log "             Devices will show no plugins, themes or hotkeys from this vault."
  fi
  if ob_q "$@"; then
    SYNC_CONFIGS_STATE="ok"
    return 0
  fi
  SYNC_CONFIGS_STATE="FAILED"
  log "WARNING: sync-config failed - conflict strategy AND config categories are unchanged."
  log "         Devices may receive no .obsidian/ config. Check the category names against"
  log "         'ob sync-config --help' for the pinned obsidian-headless version."
  return 1
}

ensure_ob_setup() {
  if ob_q sync-status --path "$VAULT_DIR"; then
    apply_sync_config   # re-assert on every boot; heals an older linked vault
    return $?   # already linked, but a rejected config is not a ready Sync
  fi
  if [ -z "$SYNC_REMOTE" ]; then
    log "WARNING: VAULT_SYNC_REMOTE unset - cannot link Sync; device sync disabled."
    return 1
  fi
  # --password is REQUIRED for an end-to-end-encrypted remote vault. Without it
  # `ob sync-setup` prompts, and a prompt in a worker is an invisible hang.
  set -- sync-setup --vault "$SYNC_REMOTE" --path "$VAULT_DIR" --device-name "$DEVICE_NAME"
  if [ -n "$SYNC_ENC_PW" ]; then
    set -- "$@" --password "$SYNC_ENC_PW"
  else
    log "NOTE: VAULT_SYNC_ENCRYPTION_PASSWORD unset - assuming an unencrypted remote."
  fi
  log "linking Sync remote '$SYNC_REMOTE' -> $VAULT_DIR"
  if ! ob_v "$@"; then
    log "WARNING: sync-setup failed (wrong vault name, wrong encryption password, or auth)."
    return 1
  fi
  apply_sync_config
  return $?
}

# OB_PID is the real `ob` process, backgrounded directly - the same rule as
# INOTIFY_PID below, and for the same reason: a retry-loop wrapper subshell dies
# on SIGTERM while its `ob` child keeps running, orphaned. On a redeploy that
# means a dead deploy's Sync client still holds the vault - the exact two-writer
# situation this daemon exists to prevent. Restart-on-death happens inline in
# the main loop (rate-limited), never via a wrapper.
HAVE_OB=0
# Only a completed Sync cycle counts as progress. Startup text and repeated
# errors must not refresh this clock or conceal a broken native transport.
start_ob_continuous() {
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  storage_check || { health_write || true; return 1; }
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  OB_STARTED_AT="$(date +%s)"; OB_GENERATION=$((OB_GENERATION+1))
  OB_RUN_ID="$$-$OB_STARTED_AT-$OB_GENERATION"
  SYNC_MODE=configured; SYNC_STATE=starting
  log "starting: ob sync --continuous --path $VAULT_DIR"
  ob sync --continuous --path "$VAULT_DIR" </dev/null \
    > >(while IFS= read -r _ob_line; do
          case "$_ob_line" in
            'Fully synced'|*'] Fully synced')
              _ob_now="$(date +%s)"
              sync_marker "$OB_ACTIVITY_FILE" "$_ob_now"
              sync_marker "$OB_SUCCESS_FILE" "$_ob_now"
              sync_marker "$OB_STATUS_FILE" "$OB_RUN_ID ready"
              ;;
            'Sync error:'*|'Sync failed:'*|'Another sync instance is already running for this vault.'|'Disconnected from server'|*'] Sync error:'*|*'] Sync failed:'*|*'] Another sync instance is already running for this vault.'|*'] Disconnected from server')
              sync_marker "$OB_STATUS_FILE" "$OB_RUN_ID error"
              ;;
          esac
          printf '[ob:%s] %s\n' "$NAME" "$_ob_line" >&2
        done) 2>&1 &
  OB_PID=$!
}

# Git can write conflict markers and partial trees before merge reports failure.
# Native Sync must observe only the completed merge or its completed abort.
# Status, local commits and fetch leave the working tree alone and need no pause.
resume_ob_after_git_merge() {
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  git_worktree_ready || { health_write || true; return 1; }
  storage_check || { health_write || true; return 1; }
  if [ "$1" = 1 ] && [ "$HAVE_OB" -eq 1 ] && ! owned_ob_running; then
    start_ob_continuous
  fi
}

# Seconds of total ob silence that count as "probably not syncing". ob narrates
# in bursts with long quiet gaps between them, so this has to sit comfortably
# above the observed gap rather than at it. 0 disables the check.
OB_SILENCE_WARN="${VAULT_OB_SILENCE_WARN:-5400}"
ob_silence_secs() {
  local last now
  last="$(sync_clock "$OB_ACTIVITY_FILE")"
  [ "$last" -gt "$OB_STARTED_AT" ] || last="$OB_STARTED_AT"
  [ "$last" -gt 0 ] || { printf unknown; return; }
  now="$(date +%s)"
  printf '%s' "$(( now - last ))"
}

if command -v ob >/dev/null 2>&1; then
  if storage_check && ensure_ob_auth && ensure_ob_setup; then
    HAVE_OB=1
    start_ob_continuous
  else
    log "WARNING: device<->bridge Sync DISABLED (git-only mode). Agent edits still sync; phone-only edits will NOT."
  fi
else
  log "WARNING: 'ob' not installed - device sync DISABLED (git-only mode)."
fi

# --- 3. Local-change detection: inotify with debounce, fail-soft ------------
HAVE_INOTIFY=0
if command -v inotifywait >/dev/null 2>&1; then
  HAVE_INOTIFY=1
else
  log "WARNING: 'inotifywait' not installed (package inotify-tools) - falling back to"
  log "         interval-only polling. Local edits will be noticed on the next poll,"
  log "         not within ~1-2s."
fi

# Debounce window: after the first event, wait for ~1s of quiet before
# reconciling, but never delay more than 5s total under continuous writing
# (Obsidian saves on every keystroke - without this, every keystroke commits).
DEBOUNCE_QUIET=1
DEBOUNCE_CAP=5

# INOTIFY_PID is always the real `inotifywait` process, backgrounded directly
# (never wrapped in a retry-loop subshell): a wrapper subshell's own PID is
# what `kill` would target, but the shell subshell itself dies immediately on
# SIGTERM while its inotifywait CHILD keeps running, orphaned and undetected -
# a real leak this daemon must never leave behind on redeploy/shutdown.
# Restart-on-death is instead handled inline by the main loop below, which is
# already polling every CURRENT_INTERVAL seconds regardless.
start_inotify_watch() {
  if [ -z "$FIFO" ]; then
    FIFO="$(mktemp -u "${TMPDIR:-/tmp}/vault-bridge-$NAME.XXXXXX")"
    if ! mkfifo "$FIFO" 2>/dev/null; then
      log "WARNING: mkfifo failed - falling back to interval-only polling."
      FIFO=""
      return 1
    fi
    # Open the fifo read-write on our own fd so it never sees EOF between
    # inotifywait (re)starts - a plain read-only open would return EOF the
    # instant the writer side closes, even momentarily during a restart.
    exec 3<>"$FIFO"
  fi
  # -r recursive, --exclude .git/ (its own commits/pulls churn there and would
  # otherwise feed back into triggering more reconciles).
  inotifywait -m -r -e close_write -e create -e delete -e move \
    --exclude '(^|/)\.git($|/)' "$VAULT_DIR" 2>/dev/null > "$FIFO" &
  INOTIFY_PID=$!
  return 0
}

if [ "$HAVE_INOTIFY" -eq 1 ]; then
  if ! start_inotify_watch; then
    HAVE_INOTIFY=0
  fi
fi

# Drain further events until ~DEBOUNCE_QUIET seconds of quiet, or until
# DEBOUNCE_CAP seconds have passed since the first event, whichever is first.
debounce_drain() {
  local start now
  start="$(date +%s)"
  while true; do
    if read -r -t "$DEBOUNCE_QUIET" -u 3 _line; then
      now="$(date +%s)"
      if [ "$(( now - start ))" -ge "$DEBOUNCE_CAP" ]; then
        return 0
      fi
      continue
    fi
    return 0   # quiet period elapsed
  done
}

# --- 4. Sync-cap guard: files over VAULT_MAX_FILE_MB are unstaged, not committed
#
# Opt-in escape hatch: an image ALREADY over the cap may be re-encoded to fit
# before the refusal applies (see compress_to_fit). The refusal itself is
# unchanged and remains the floor - if the re-encode does not get the file under
# the cap, the file is withheld exactly as it always was.
enforce_size_cap() {
  [ "$MAX_FILE_MB" -gt 0 ] || return 0
  local max_bytes=$(( MAX_FILE_MB * 1024 * 1024 ))
  local f path size size_mb
  # core.quotePath=false: a non-ASCII filename would otherwise come back
  # git-quoted (\xxx), fail the [ -f ] test, and slip past the cap uncommitted-
  # guard - reintroducing the silent oversize divergence this exists to stop.
  git -C "$VAULT_DIR" -c core.quotePath=false diff --cached --name-only 2>/dev/null | while IFS= read -r f; do
    path="$VAULT_DIR/$f"
    # A deleted/renamed-away path has nothing to measure - not a cap violation.
    [ -f "$path" ] || continue
    size="$(stat -c%s "$path" 2>/dev/null || wc -c < "$path" 2>/dev/null || echo 0)"
    if [ "$size" -gt "$max_bytes" ]; then
      # Only reached by a file that is ALREADY refused today. A no-op unless
      # compression is switched on, and it returns 0 only when the file on disk
      # is now genuinely under the cap and re-staged.
      compress_to_fit "$f" "$path" "$size" "$max_bytes" && continue
      git -C "$VAULT_DIR" reset -q -- "$f" 2>/dev/null
      size_mb=$(( (size + 1048575) / 1048576 ))
      log "WARNING: $f exceeds sync cap (${size_mb} MB) - NOT committed; raise VAULT_MAX_FILE_MB or use LFS+exclusion deliberately"
    fi
  done
}

# --- 4a. Opt-in image compression, tried only where the cap would otherwise
#         refuse outright ----------------------------------------------------
# The daemon is content-agnostic everywhere else: it moves bytes and resolves
# conflicts, and never inspects or rewrites what is inside a file. This is the
# one exception, and re-encoding is lossy and irreversible - for a photo the
# vault may hold the only remaining copy. So it is deliberately narrow and loud:
#
#   - OFF unless VAULT_COMPRESS_IMAGES is set truthy. Nobody's behaviour changes
#     without opting in.
#   - Only files ALREADY over the cap. Under the cap, nothing is ever touched.
#   - Only an explicit image-extension allowlist, matched case-insensitively.
#     No other file type is ever rewritten.
#   - Never an LFS-tracked path (see below).
#   - The replacement is decoded and verified before it overwrites anything.
#   - Every re-encode logged with the path and its before/after sizes.
#   - The hard refusal stays the floor: a file that cannot be brought under the
#     cap is withheld exactly as before. A still-oversized file is never
#     committed, whatever this function does.
compress_enabled() {
  case "${VAULT_COMPRESS_IMAGES:-0}" in
    1|on|ON|true|TRUE|True|yes|YES|Yes) return 0 ;;
    *)                                  return 1 ;;
  esac
}

# Whichever image tool is present, preferring libvips: it is small, fast,
# low-memory, has a far better CVE record than ImageMagick, and is what the
# container ships (see Dockerfile). python3 + Pillow is the fallback for a
# bridge running outside that image. Neither present => prints nothing, and
# compression never happens - same capability-detection shape as inotifywait,
# ob and git-lfs elsewhere in this daemon.
image_backend() {
  if command -v vips >/dev/null 2>&1; then
    printf 'vips'
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' >/dev/null 2>&1; then
    printf 'pillow'
  fi
}

# Re-encode $src into $dst at quality $q, longest side capped at $dim px
# (0 = keep the original dimensions). The output format is chosen from $dst's
# extension by BOTH backends, so a mislabelled file cannot silently change type.
# Never upscales. Returns non-zero if the encode fails for any reason.
image_reencode() {
  local backend="$1" src="$2" dst="$3" q="$4" dim="$5" ext opts
  ext="$(printf '%s' "${dst##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$backend" in
    vips)
      # PNG has no quality knob; `palette` is libvips' lossy-PNG equivalent.
      case "$ext" in
        png) opts="[Q=$q,palette]" ;;
        *)   opts="[Q=$q]" ;;
      esac
      if [ "$dim" -gt 0 ]; then
        vips thumbnail "$src" "$dst$opts" "$dim" --size down >/dev/null 2>&1
      else
        vips copy "$src" "$dst$opts" >/dev/null 2>&1
      fi
      ;;
    pillow)
      python3 - "$src" "$dst" "$q" "$dim" >/dev/null 2>&1 <<'PYEOF'
import os
import sys

from PIL import Image

src, dst, q, dim = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
ext = os.path.splitext(dst)[1].lower().lstrip(".")
fmt = {"jpg": "JPEG", "jpeg": "JPEG", "png": "PNG", "webp": "WEBP"}.get(ext)
if not fmt:
    sys.exit(3)
im = Image.open(src)
im.load()
if dim > 0:
    im.thumbnail((dim, dim))          # never upscales
if fmt == "JPEG":
    if im.mode not in ("RGB", "L"):
        im = im.convert("RGB")
    im.save(dst, fmt, quality=q, optimize=True)
elif fmt == "PNG":
    if im.mode in ("RGBA", "LA", "PA"):
        im = im.quantize(colors=256, method=2)   # FASTOCTREE keeps alpha
    elif im.mode != "P":
        im = im.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=256)
    im.save(dst, fmt, optimize=True)
else:
    im.save(dst, fmt, quality=q)
PYEOF
      ;;
    *) return 1 ;;
  esac
}

# Fully DECODE an image and fail if it is truncated or corrupt. This runs on the
# re-encoded candidate before it is allowed to overwrite the original, because a
# non-zero exit from the encoder is the only other thing standing between a
# half-written file and the user's only copy of a photo.
#
# The exact incantations matter and were measured, not assumed:
#   - `vips header` is NOT a libvips action (the binary is `vipsheader`), so it
#     exits non-zero on every file, good or bad - a check like that would have
#     silently disabled compression rather than guarding it.
#   - plain `vips avg` returns SUCCESS on a JPEG truncated to half its bytes;
#     libvips fills the missing scanlines and carries on. `fail_on=truncated` is
#     what actually turns that into an error.
image_verify() {
  local backend="$1" path="$2"
  [ -s "$path" ] || return 1
  case "$backend" in
    vips)   vips avg "${path}[fail_on=truncated]" >/dev/null 2>&1 ;;
    pillow) python3 - "$path" >/dev/null 2>&1 <<'PYEOF'
import sys

from PIL import Image

im = Image.open(sys.argv[1])
im.load()          # raises on a truncated or corrupt file
PYEOF
      ;;
    *) return 1 ;;
  esac
}

# Force one file (or directory) out of the page cache and onto the disk.
# `rename()` orders metadata; it does NOT promise that the bytes the new name
# points at have been written. Without this, a crash immediately after the swap
# can leave the destination naming a file full of zeroes - which is the same
# data loss this whole construction exists to prevent, arriving one step later.
#
# Three implementations because there is no fsync builtin in shell, in
# decreasing precision: coreutils >= 8.24 `sync FILE` syncs exactly that path
# (this is what the container has); python3 does the same syscall directly; a
# bare `sync` flushes the entire system, which is heavy but never wrong. Only
# the last is a fallback in the "should not happen" sense - it still syncs.
fsync_path() {
  sync "$1" 2>/dev/null && return 0
  command -v python3 >/dev/null 2>&1 && python3 -c '
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
' "$1" 2>/dev/null && return 0
  sync 2>/dev/null || true
}

# Replace $2 with $1 so that a reader - or a crash - never sees anything but one
# of the two whole files.
#
# This exists because `cat "$src" > "$dst"` does NOT: the shell truncates $dst
# when it opens it, so from that instant until the copy finishes the only copy
# of the destination's contents is gone. That is survivable when git holds a
# copy; on the compression path it is not, because a file only reaches that path
# by being OVER the size cap, which means it was refused and therefore never
# committed. Killed mid-`cat` on a 3 MB image, 4096 bytes survived and the rest
# was unrecoverable from anywhere. So: write beside the destination, fsync, then
# rename(), which POSIX requires to be atomic within a single filesystem.
#
# What that trades, stated plainly because the comment this replaces did not:
#
#   - PRESERVED, and deliberately: the destination's mode and ownership, copied
#     onto the temp before the swap. A vault file that was 0644 root:root stays
#     0644 root:root; the old `cat` kept them for free, this does it by hand.
#   - LOST: inode identity. rename() puts a NEW inode at the path, so the inode
#     number changes and any pre-existing hardlink keeps pointing at the old
#     content. Nothing here depends on either: the inotify watch is recursive
#     over DIRECTORIES (see start_inotify_watch), so it follows the path rather
#     than the inode and sees the rename as a normal event; git stores content,
#     not inodes, and rewrites inodes itself on every checkout. Atomicity is
#     worth more than an identity no reader in this system consults.
#   - REFUSED, never silently degraded: a cross-filesystem source. `mv` across
#     devices is a copy-then-unlink, which has exactly the truncation window
#     this function exists to close, so the device check below fails the call
#     instead. The caller then applies its ordinary refusal and the original
#     file is left untouched - the safe outcome, not a corrupted one.
replace_file_atomically() {
  local src="$1" dst="$2" src_dev dst_dev mode
  src_dev="$(stat -c%d "$(dirname "$src")" 2>/dev/null)" || return 1
  dst_dev="$(stat -c%d "$(dirname "$dst")" 2>/dev/null)" || return 1
  [ -n "$src_dev" ] && [ "$src_dev" = "$dst_dev" ] || return 1
  mode="$(stat -c%a "$dst" 2>/dev/null)" && chmod "$mode" "$src" 2>/dev/null
  chown --reference="$dst" "$src" 2>/dev/null || true
  fsync_path "$src"
  mv -f "$src" "$dst" 2>/dev/null || return 1
  # And make the rename itself durable, not just the bytes it now points at.
  fsync_path "$(dirname "$dst")"
  return 0
}

# Try to bring an already-oversize image under the cap. Returns 0 ONLY when the
# working-tree file is now genuinely under the cap and re-staged; every other
# outcome returns non-zero so the caller applies the unchanged hard refusal.
compress_to_fit() {
  local rel="$1" path="$2" orig="$3" max_bytes="$4"
  compress_enabled || return 1

  # Raster formats that survive a re-encode into THE SAME extension.
  # Deliberately excludes .gif (would lose animation), .svg (vector - there is
  # no "re-encode", only rewriting markup), and .heic/.tiff (Obsidian does not
  # render them anyway, so a lossy rewrite buys nothing).
  local image_exts="jpg jpeg png webp"
  local ext
  ext="$(printf '%s' "${rel##*.}" | tr '[:upper:]' '[:lower:]')"
  # KEEP "$ext" QUOTED. An extension is just part of a filename, so it can
  # legitimately contain glob metacharacters - and an unquoted expansion in a
  # `case` pattern is a pattern, not a string: 'photo.j[p]g' would then match
  # 'jpg' and be sent to an encoder that cannot write that file. Quoted, it is
  # compared literally, which is what an allowlist means. (Verified both ways;
  # test_image_compression.sh case 8c fails if the quotes are dropped.)
  case " $image_exts " in
    *" $ext "*) ;;
    *)          return 1 ;;
  esac

  # An LFS-tracked path is committed as a small pointer whatever the working
  # tree holds, so re-encoding it would destroy pixels for no size gain at all.
  # (The cap itself measures the working-tree file and therefore still refuses
  # such a path at full size - a pre-existing quirk this change does not alter.)
  if git -C "$VAULT_DIR" check-attr filter -- "$rel" 2>/dev/null | grep -q ': filter: lfs$'; then
    log "COMPRESS: skipping '$rel' - it is git-lfs tracked, so a re-encode would lose"
    log "          pixels without shrinking what git actually stores."
    return 1
  fi

  local backend
  backend="$(image_backend)"
  if [ -z "$backend" ]; then
    log "COMPRESS: '$rel' is over the cap and VAULT_COMPRESS_IMAGES is on, but no image"
    log "          tool is available (install libvips-tools, or python3 with Pillow)."
    log "          Refusing the file exactly as if compression were off."
    return 1
  fi

  # Quality first, then progressively smaller dimensions. Stops at the FIRST
  # rung that fits, so the least destructive re-encode that works is the one
  # that ships.
  local work tmp rung q dim dimnote new tmp_home
  # The re-encode is written where it will be renamed FROM, and a rename is only
  # atomic within one filesystem - so the scratch space has to live on the
  # vault's own volume, not in /tmp (which is a separate tmpfs in the container:
  # a /tmp temp plus `mv` is a cross-device copy, i.e. no atomicity at all).
  #
  # $VAULT_DIR/.git is the one directory that is guaranteed to be both on that
  # filesystem and invisible to the rest of this daemon: git never tracks its
  # own directory, and the inotify watch excludes it by name. Scratch inside the
  # vault TREE would instead be staged by the next `git add -A` if the process
  # died mid-encode, committing a half-written image under a junk filename.
  tmp_home="$VAULT_DIR/.git"
  [ -d "$tmp_home" ] || return 1
  # Sweep any scratch left behind by an earlier kill. Safe to do unconditionally
  # because the reconcile loop is single-threaded: no other pass can be holding
  # one of these while this one runs.
  rm -rf "$tmp_home"/vault-bridge-compress.* 2>/dev/null || true
  work="$(mktemp -d "$tmp_home/vault-bridge-compress.XXXXXX" 2>/dev/null)" || return 1
  tmp="$work/reencoded.$ext"
  for rung in "88 0" "80 2560" "72 1800" "64 1280"; do
    q="${rung%% *}"; dim="${rung##* }"
    rm -f "$tmp"
    image_reencode "$backend" "$path" "$tmp" "$q" "$dim" || continue
    [ -s "$tmp" ] || continue
    new="$(stat -c%s "$tmp" 2>/dev/null || wc -c < "$tmp" 2>/dev/null || echo 0)"
    # A "compression" that grew the file is not one. Never write it back.
    [ "$new" -lt "$orig" ] || continue
    [ "$new" -le "$max_bytes" ] || continue
    # Last gate before the original is destroyed: the candidate must decode.
    image_verify "$backend" "$tmp" || continue
    # The original is destroyed HERE, and git has no copy of it (it was refused
    # for being over the cap), so the swap has to be all-or-nothing. See
    # replace_file_atomically: it preserves mode and ownership, fsyncs, and
    # renames. A failure leaves the original exactly as it was.
    replace_file_atomically "$tmp" "$path" || { rm -rf "$work"; return 1; }
    rm -rf "$work"
    git -C "$VAULT_DIR" add -- "$rel" 2>/dev/null || return 1
    if [ "$dim" -gt 0 ]; then dimnote=", longest side ${dim}px"; else dimnote=", original dimensions"; fi
    log "COMPRESSED: '$rel' $(( (orig + 1048575) / 1048576 )) MB -> $(( (new + 1048575) / 1048576 )) MB" \
        "(${orig} -> ${new} bytes; ${backend}, quality ${q}${dimnote})" \
        "- now under the ${MAX_FILE_MB} MB sync cap, committing it"
    return 0
  done
  rm -rf "$work"
  log "COMPRESS: could not bring '$rel' under the ${MAX_FILE_MB} MB cap - re-encoding was"
  log "          tried down to 1280px and it is still too big. Refusing it as usual."
  return 1
}

# --- 4b. Mass-deletion guard: refuse to propagate a vault-emptying commit -----
# The size cap stops a bad ADD reaching git. This is its missing counterpart for
# a bad DELETE, and the asymmetry mattered: anything that empties the working
# tree - a bad first-link reconciliation on the Obsidian side, a misconfigured
# mount, an operator's stray rm, a bug - was staged, committed and PUSHED within
# one poll cycle, and from there to every device. Git history keeps the notes, so
# this is recoverable, but only after it has already propagated everywhere.
#
# "Refuse rather than corrupt" is a design law here, so a pass that would delete
# most of the vault stops and says so instead of guessing. A genuine bulk
# deletion is then one deliberate act: set VAULT_MAX_DELETE_PCT (or 0 to disable
# the guard entirely) and redeploy, or make the deletion as a normal git commit
# from a clone, which the daemon will happily fast-forward.
MAX_DELETE_PCT="${VAULT_MAX_DELETE_PCT:-50}"
MIN_DELETE_FLOOR="${VAULT_MIN_DELETE_FLOOR:-10}"
DELETE_GRACE_SECS="${VAULT_DELETE_GRACE_SECS:-600}"
DELETE_HOLD_SINCE=0
DELETE_HOLD_SIG=""
guard_mass_deletion() {
  [ "$MAX_DELETE_PCT" -gt 0 ] || return 0
  local deleted tracked pct
  deleted="$(git -C "$VAULT_DIR" diff --cached --name-only --diff-filter=D 2>/dev/null | wc -l)"
  [ "$deleted" -ge "$MIN_DELETE_FLOOR" ] || return 0
  tracked="$(git -C "$VAULT_DIR" ls-tree -r --name-only HEAD 2>/dev/null | wc -l)"
  [ "$tracked" -gt 0 ] || return 0
  pct=$(( deleted * 100 / tracked ))
  [ "$pct" -ge "$MAX_DELETE_PCT" ] || return 0
  # Hold, then proceed. A mass deletion that is REAL (the owner reorganising)
  # persists; the failure modes this guards against (a bad first-link
  # reconciliation, a half-mounted volume, a transient emptied tree) resolve or
  # get noticed inside the grace window. So refuse loudly at first sight and
  # keep refusing while it is fresh, then let it through rather than leaving a
  # vault permanently stuck for someone with no way to override it.
  local now_del
  now_del="$(date +%s)"
  if [ "$DELETE_HOLD_SINCE" -eq 0 ] || [ "$DELETE_HOLD_SIG" != "$deleted/$tracked" ]; then
    DELETE_HOLD_SINCE="$now_del"
    DELETE_HOLD_SIG="$deleted/$tracked"
  fi
  local held=$(( now_del - DELETE_HOLD_SINCE ))
  if [ "$held" -ge "$DELETE_GRACE_SECS" ]; then
    log "PROCEEDING with the large deletion (${deleted}/${tracked}, ${pct}%) after ${held}s:"
    log "         it persisted through the grace window, so it reads as intended."
    log "         Every deleted file remains recoverable from git history."
    DELETE_HOLD_SINCE=0
    DELETE_HOLD_SIG=""
    return 0
  fi
  log "HOLDING a large deletion: ${deleted} of ${tracked} tracked files (${pct}%)."
  log "         Nothing committed or pushed yet, and nothing in git is lost."
  log "         If this was NOT intended, restore the files in $VAULT_DIR now -"
  log "         otherwise it proceeds automatically in $(( DELETE_GRACE_SECS - held ))s."
  return 1
}

# --- 5. The single reconcile pass, shared by both triggers -------------------
# Network git operations get a hard timeout: a hung push otherwise blocks the
# single-threaded loop indefinitely (inotify events back up in the fifo until
# the pipe fills and the watcher itself blocks - measured, not hypothetical).
GIT_TIMEOUT="${VAULT_GIT_TIMEOUT:-60}"
git_net() { timeout "$GIT_TIMEOUT" git -C "$VAULT_DIR" "$@"; }

# A same-region collision git cannot merge is resolved the way Obsidian Sync
# surfaces its own: the device/local side stays in the note (human keystrokes
# win the visible file), and the remote/agent side is committed beside it as
# "Note (conflicted copy <timestamp>).md" - so the conflict appears ON DEVICES,
# inside Obsidian, not in a server log. Both sides are in git history either
# way; nothing is lost. Any per-file failure aborts the merge and reverts to
# the old freeze-and-log behaviour (fail-soft, never guess).
#
# EXCEPT under a hidden path - see hidden_path() below.

# True when ANY component of a repo-relative path starts with a dot: a dotfolder
# ('.agent-memory/sessions/x.md', '.obsidian/appearance.json') or a dotfile
# ('.gitignore'). Obsidian renders neither, which is the whole point: a
# conflicted copy is a SURFACING mechanism, and one written here surfaces
# nowhere. The vault repo's own .gitignore says so explicitly - conflicted
# copies are deliberately not ignored "so it appears on every device, inside
# Obsidian" - and a copy no device renders is the silent failure that comment
# exists to prevent, committed and pushed with a single log line as its only
# trace.
hidden_path() {
  case "/$1" in
    */.*) return 0 ;;
    *)    return 1 ;;
  esac
}
resolve_conflicts_sync_style() {
  local ts f base ext copy count=0
  ts="$(date -u '+%Y-%m-%d %H.%M.%S')"
  local dir fn made_copy unmerged hidden_hits=""
  unmerged="$(git -C "$VAULT_DIR" diff --name-only --diff-filter=U 2>/dev/null)"

  # Check EVERY conflicted path before touching any of them. This resolver
  # commits all of its work in one commit, so a mixed set (a note plus a
  # dotfolder file) must not half-resolve: returning 1 here leaves the merge
  # exactly as git left it, which is what the caller's `merge --abort` needs to
  # restore a clean tree.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hidden_path "$f" && hidden_hits="$hidden_hits '$f'"
  done <<EOF
$unmerged
EOF
  if [ -n "$hidden_hits" ]; then
    log "CONFLICT under a hidden path -$hidden_hits"
    log "         NO conflicted copy was made: Obsidian shows neither dotfolders nor"
    log "         dotfiles, so the copy would be invisible on every device - a conflict"
    log "         resolved into a file nobody can see. Stopping instead, loudly."
    log "         Nothing is lost: git history holds both sides. Resolve it in a clone."
    return 1
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Split the extension off the FILE NAME only, never the path - a note in a
    # dot-containing directory ("my.notes/README") must not have the dot in the
    # directory treated as the extension, which would target a nonexistent dir.
    dir="$(dirname "$f")"; fn="$(basename "$f")"
    case "$fn" in
      *.*) base="${fn%.*}"; ext=".${fn##*.}" ;;
      *)   base="$fn";      ext="" ;;
    esac
    if [ "$dir" = "." ]; then copy="$base (conflicted copy $ts)$ext"
    else copy="$dir/$base (conflicted copy $ts)$ext"; fi
    made_copy=0
    # stage :2 = ours (local/device), :3 = theirs (remote/agent).
    if git -C "$VAULT_DIR" cat-file -e ":3:$f" 2>/dev/null; then
      git -C "$VAULT_DIR" show ":3:$f" > "$VAULT_DIR/$copy" 2>/dev/null || return 1
      made_copy=1
    fi
    # Stage exactly the paths that now EXIST. Staging a pathspec that matches
    # nothing makes `git add` fail for the whole invocation, which stages
    # nothing at all and wedges the branch on every later pass - so each side of
    # this decision adds only what it actually produced. Both directions of a
    # modify/delete are covered, and each is regression-tested.
    if git -C "$VAULT_DIR" cat-file -e ":2:$f" 2>/dev/null; then
      # We still have it: the device/local side stays in the visible note.
      git -C "$VAULT_DIR" checkout --ours -- "$f" 2>/dev/null || return 1
      git -C "$VAULT_DIR" add -- "$f" 2>/dev/null || return 1
      if [ "$made_copy" -eq 1 ]; then
        git -C "$VAULT_DIR" add -- "$copy" 2>/dev/null || return 1
        log "CONFLICT: '$f' collided - device version kept in place, other side saved as '$copy'"
      else
        # Theirs was a delete: nothing to save beside it, the edit simply wins.
        log "CONFLICT: '$f' edited here, deleted on the other side - edit kept in place"
      fi
    else
      # We deleted it, they modified it: the deletion stands in the main path
      # and their modification survives as the copy. The main path no longer
      # exists, so it must NOT appear in the add - only the copy does.
      git -C "$VAULT_DIR" rm -q --cached -- "$f" 2>/dev/null || return 1
      rm -f "$VAULT_DIR/$f" 2>/dev/null
      if [ "$made_copy" -eq 1 ]; then
        git -C "$VAULT_DIR" add -- "$copy" 2>/dev/null || return 1
        log "CONFLICT: '$f' deleted here, modified on the other side - their version saved as '$copy'"
      fi
    fi
    count=$(( count + 1 ))
  done <<EOF
$unmerged
EOF
  [ "$count" -gt 0 ] || return 1
  # Conflicted copies are staged blobs like any other: apply the same cap here,
  # or an oversized losing side reaches git and never reaches a device.
  enforce_size_cap
  git -C "$VAULT_DIR" commit -q --no-edit 2>/dev/null || return 1
  return 0
}

# Sets RECONCILE_ACTIVITY=1 iff this pass actually moved something (a remote
# commit landed, or a local commit was made) - used to drive the adaptive poll.
HEARTBEAT_SECS="${VAULT_HEARTBEAT_SECS:-900}"
COMMIT_FAIL_COUNT=0
LAST_HEARTBEAT=0

RECONCILE_ACTIVITY=0
reconcile_pass() {
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
  RECONCILE_ACTIVITY=0
  local before_rev after_rev dirty rc resume_ob=0
  if ! storage_check; then stop_owned_ob || true; health_write || true; return; fi
  if ! git_worktree_ready; then stop_owned_ob || true; health_write || true; return; fi
  GIT_STATE=pending; GIT_REASON=reconciling; LAST_GIT_RC=0
  dirty="$(git -C "$VAULT_DIR" status --porcelain 2>"$GIT_ERROR_FILE")"; rc=$?
  if [ "$rc" -ne 0 ]; then git_failure status "$rc"; return; fi

  # Device bytes enter history before a merge can touch the working tree.
  if [ -n "$dirty" ]; then
    storage_check || { health_write || true; return; }
    git -C "$VAULT_DIR" add -A 2>"$GIT_ERROR_FILE"; rc=$?
    if [ "$rc" -ne 0 ]; then git_failure stage "$rc"; return; fi
    enforce_size_cap
    if ! guard_mass_deletion; then
      git -C "$VAULT_DIR" reset -q 2>/dev/null || true
      GIT_STATE=held; GIT_REASON=deletion_held; health_write || true; return
    fi
    if ! git -C "$VAULT_DIR" diff --cached --quiet 2>/dev/null; then
      storage_check || { health_write || true; return; }
      if git -C "$VAULT_DIR" commit -q -m "vault sync: $(date -u +%FT%TZ)" 2>"$GIT_ERROR_FILE"; then
        RECONCILE_ACTIVITY=1
      else
        rc=$?; COMMIT_FAIL_COUNT=$((COMMIT_FAIL_COUNT+1))
        git_failure commit "$rc"; return
      fi
    fi
  fi

  before_rev="$(git -C "$VAULT_DIR" rev-parse HEAD 2>/dev/null || true)"
  storage_check || { health_write || true; return; }
  git_net fetch origin "$VAULT_BRANCH" >/dev/null 2>"$GIT_ERROR_FILE"; rc=$?
  if [ "$rc" -ne 0 ]; then git_failure fetch "$rc"; return; fi
  LAST_FETCH_SUCCESS="$(date +%s)"
  if ! git -C "$VAULT_DIR" merge-base --is-ancestor "origin/$VAULT_BRANCH" HEAD 2>/dev/null; then
    storage_check || { health_write || true; return; }
    if owned_ob_running; then
      resume_ob=1
      if ! stop_owned_ob; then
        GIT_STATE=held; GIT_REASON=sync_stop_failed; LAST_GIT_RC=0
        log 'WARNING: Git merge held: managed Native Sync has not stopped; working tree retained.'
        health_write || true; return
      fi
    fi
    [ "$SHUTDOWN_REQUESTED" -eq 0 ] || exit 0
    # Native may have finished a save after the first commit but during fetch.
    # No Git mutation has started yet: preserve it for the next local commit.
    dirty="$(git -C "$VAULT_DIR" status --porcelain 2>"$GIT_ERROR_FILE")"; rc=$?
    if [ "$rc" -ne 0 ]; then git_failure status "$rc"; return; fi
    if [ -n "$dirty" ]; then
      GIT_STATE=held; GIT_REASON=local_changes_after_sync_stop; LAST_GIT_RC=0
      log 'WARNING: incoming Git mutation deferred: final Native writes remain for the next local commit.'
      resume_ob_after_git_merge "$resume_ob" || true
      health_write || true; return
    fi
    git_intent_begin || return
    if ! git -C "$VAULT_DIR" merge --no-edit "origin/$VAULT_BRANCH" >/dev/null 2>"$GIT_ERROR_FILE"; then
      if ! resolve_conflicts_sync_style; then
        if git -C "$VAULT_DIR" merge --abort >/dev/null 2>"$GIT_ERROR_FILE"; then
          git_intent_finish || return
        else
          GIT_MUTATION_HELD=1
          GIT_STATE=held; GIT_REASON=worktree_mutation_incomplete; LAST_GIT_RC=1
          log 'WARNING: Git abort did not complete; persistent intent and all working bytes retained.'
          health_write || true; return
        fi
        GIT_STATE=failed; GIT_REASON=merge_failed; LAST_GIT_RC=1
        log "WARNING: merge failed and conflicted-copy resolution also failed -"
        log "         leaving tree as-is (retrying next pass; never force-pushing)."
        resume_ob_after_git_merge "$resume_ob" || true
        health_write || true; return
      fi
    fi
    git_intent_finish || return
    resume_ob_after_git_merge "$resume_ob" || return
  fi
  after_rev="$(git -C "$VAULT_DIR" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$after_rev" ] && [ "$after_rev" != "$before_rev" ] && RECONCILE_ACTIVITY=1

  if ! git -C "$VAULT_DIR" merge-base --is-ancestor HEAD "origin/$VAULT_BRANCH" 2>/dev/null; then
    storage_check || { health_write || true; return; }
    git_net push origin "$VAULT_BRANCH" >/dev/null 2>"$GIT_ERROR_FILE"; rc=$?
    if [ "$rc" -ne 0 ]; then git_failure push "$rc"; return; fi
    LAST_PUSH_SUCCESS="$(date +%s)"
  fi
  GIT_STATE=ok; GIT_REASON=ok; LAST_GIT_RC=0
  dirty="$(git -C "$VAULT_DIR" status --porcelain 2>"$GIT_ERROR_FILE")"; rc=$?
  if [ "$rc" -ne 0 ]; then git_failure status "$rc"; return; fi
  if [ -n "$dirty" ]; then GIT_STATE=held; GIT_REASON=local_changes_withheld
  else LAST_RECONCILE_SUCCESS="$(date +%s)"; fi
  health_write || true
}

# --- 6. Reconcile loop: event-driven + adaptive periodic, one at a time -----
if [ -n "$LEGACY_INTERVAL" ]; then
  log "reconcile loop: legacy fixed interval ${LEGACY_INTERVAL}s on branch ${VAULT_BRANCH}"
else
  log "reconcile loop: adaptive poll ${POLL_ACTIVE}s active / ${POLL_IDLE}s idle" \
    "(window ${ACTIVE_WINDOW}s) on branch ${VAULT_BRANCH}, inotify=${HAVE_INOTIFY}"
fi

LAST_ACTIVITY="$(date +%s)"
CURRENT_INTERVAL="$POLL_ACTIVE"

update_interval() {
  if [ -n "$LEGACY_INTERVAL" ]; then
    CURRENT_INTERVAL="$LEGACY_INTERVAL"
    return
  fi
  local now
  now="$(date +%s)"
  if [ "$(( now - LAST_ACTIVITY ))" -le "$ACTIVE_WINDOW" ]; then
    CURRENT_INTERVAL="$POLL_ACTIVE"
  else
    # Progressive backoff toward the idle rate rather than an immediate jump,
    # so a burst of activity that just ended doesn't instantly go quiet-slow.
    CURRENT_INTERVAL=$(( CURRENT_INTERVAL * 2 ))
    [ "$CURRENT_INTERVAL" -gt "$POLL_IDLE" ] && CURRENT_INTERVAL="$POLL_IDLE"
    [ "$CURRENT_INTERVAL" -lt "$POLL_ACTIVE" ] && CURRENT_INTERVAL="$POLL_ACTIVE"
  fi
}

OB_RESTART_AFTER=0
while true; do
  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || break
  if [ "$HAVE_INOTIFY" -eq 1 ] && ! kill -0 "$INOTIFY_PID" 2>/dev/null; then
    log "WARNING: inotifywait died - restarting watch"
    start_inotify_watch
  fi

  # Capacity is independent of child liveness. A healthy-looking process must
  # not keep consuming the last bytes; a blocked one must not restart-loop.
  if ! storage_check; then
    stop_owned_ob || true
    health_write || true
  elif ! git_worktree_ready; then
    stop_owned_ob || true
    health_write || true
  elif ! owned_ob_running; then
    [ -z "$OB_PID" ] || { wait "$OB_PID" 2>/dev/null || true; OB_PID=""; }
    [ "$SYNC_MODE" != configured ] || SYNC_STATE=not_ready
    now_ts="$(date +%s)"
    if [ "$now_ts" -ge "$OB_RESTART_AFTER" ] && command -v ob >/dev/null 2>&1; then
      if [ "$HAVE_OB" -eq 1 ]; then
        log "WARNING: ob sync exited - restarting after storage preflight"
        start_ob_continuous || true
      elif [ "$SYNC_MODE" = configured ] && ensure_ob_auth && ensure_ob_setup; then
        HAVE_OB=1; start_ob_continuous || true
      fi
      OB_RESTART_AFTER=$((now_ts+5))
    fi
    health_write || true
  fi
  cache_maintenance

  # Heartbeat. Every pass is silent on success by design (only WARNING/FATAL/
  # CONFLICT log), which means an operator reading logs cannot tell a healthy
  # quiet daemon from a wedged one - a review hit exactly that wall. This prints
  # one line per HEARTBEAT_SECS with the git-level state, so liveness is
  # answerable from logs alone. 0 disables.
  if [ "$HEARTBEAT_SECS" -gt 0 ]; then
    now_hb="$(date +%s)"
    if [ $(( now_hb - LAST_HEARTBEAT )) -ge "$HEARTBEAT_SECS" ]; then
      LAST_HEARTBEAT="$now_hb"
      hb_head="$(git -C "$VAULT_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
      hb_dirty="$(git -C "$VAULT_DIR" status --porcelain 2>/dev/null | wc -l)"
      hb_obq="$(ob_silence_secs)"
      # configs= is a plain variable read, so it costs nothing and answers the
      # question no log line could answer before: which .obsidian/ categories
      # this daemon asked Sync to carry, and whether that ask succeeded.
      log "heartbeat: HEAD=$hb_head uncommitted=$hb_dirty poll=${CURRENT_INTERVAL}s ob=${HAVE_OB} ob_quiet=${hb_obq}s configs=${SYNC_CONFIGS_STATE}:${SYNC_CONFIGS:-none}"
      # The one failure this daemon could not see before: ob alive, git syncing,
      # devices silently receiving nothing.
      if [ "$HAVE_OB" -eq 1 ] && [ "$OB_SILENCE_WARN" -gt 0 ] && \
         [ "$hb_obq" != "unknown" ] && [ "$hb_obq" -ge "$OB_SILENCE_WARN" ]; then
        log "WARNING: ob has produced no output for ${hb_obq}s. The process is alive but may"
        log "         not be syncing - device edits may not be arriving, and yours may not be"
        log "         reaching devices, while git continues normally. Check the Sync remote."
      fi
    fi
  fi

  triggered_by_event=0
  if [ "$HAVE_INOTIFY" -eq 1 ]; then
    if read -r -t "$CURRENT_INTERVAL" -u 3 _line; then
      triggered_by_event=1
      debounce_drain
    fi
  else
    bridge_pause "$CURRENT_INTERVAL"
  fi

  [ "$SHUTDOWN_REQUESTED" -eq 0 ] || break

  reconcile_pass

  if [ "$triggered_by_event" -eq 1 ] || [ "$RECONCILE_ACTIVITY" -eq 1 ]; then
    LAST_ACTIVITY="$(date +%s)"
  fi
  update_interval
done

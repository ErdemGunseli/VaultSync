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
#     conflicts appear. Never force-push; git history keeps every side of every
#     conflict, so nothing is ever lost.
#   - Refuse rather than corrupt: a file over the Sync cap is never committed, and
#     a pass that would delete most of the vault is refused outright (see
#     guard_mass_deletion) - git keeps everything, but a vault-emptying commit
#     would otherwise reach every device within one poll.
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
#   VAULT_SYNC_REMOTE                 Obsidian Sync remote vault name or id
#   VAULT_SYNC_ENCRYPTION_PASSWORD    E2E encryption password (REQUIRED if the
#                                     remote vault is encrypted - omitting it
#                                     makes `ob sync-setup` prompt, which fails
#                                     headless)
#   VAULT_SYNC_CONFIGS                optional comma list for `ob sync-config --configs`
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
SYNC_CONFIGS="${VAULT_SYNC_CONFIGS:-}"
DEVICE_NAME="${VAULT_DEVICE_NAME:-vault-bridge-$NAME}"
GIT_NAME="${GIT_AUTHOR_NAME:-vault-bridge}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-vault-bridge@localhost}"
OB_PID=""

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

# `ob` must never inherit a TTY or a readable stdin: a prompt in a background
# worker hangs forever and is invisible. Fail fast instead. Every ob call is also
# time-bounded. Without this a network stall in sync-setup hung the
# bridge before it ever reached the reconcile loop - and supervise() restarts a
# vault only when its child EXITS, so a hang meant that vault silently stopped
# syncing for the life of the container with nothing in the log to say so.
OB_TIMEOUT="${VAULT_OB_TIMEOUT:-120}"
ob_q() { timeout "$OB_TIMEOUT" ob "$@" </dev/null >/dev/null 2>&1; }
ob_v() { timeout "$OB_TIMEOUT" ob "$@" </dev/null; }

INOTIFY_PID=""
FIFO=""

cleanup() {
  if [ -n "$OB_PID" ] && kill -0 "$OB_PID" 2>/dev/null; then
    kill "$OB_PID" 2>/dev/null || true
    wait "$OB_PID" 2>/dev/null || true
  fi
  if [ -n "$INOTIFY_PID" ] && kill -0 "$INOTIFY_PID" 2>/dev/null; then
    kill "$INOTIFY_PID" 2>/dev/null || true
    wait "$INOTIFY_PID" 2>/dev/null || true
  fi
  exec 3<&- 2>/dev/null || true
  [ -n "$FIFO" ] && rm -f "$FIFO" 2>/dev/null || true
}
# INT/TERM must actually terminate the process, not just run cleanup and let
# the infinite reconcile loop resume - bash does NOT exit a trapped signal by
# default, so without the explicit `exit` a redeploy's kill would leave the
# bridge running past its supervisor's expectations. EXIT covers normal/error
# returns; cleanup() is idempotent so running it twice (TERM's handler, then
# the EXIT trap it triggers) is harmless.
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# --- 0. Unconfigured => idle without error -----------------------------------
if [ -z "$VAULT_REPO" ]; then
  log "VAULT_REPO unset - bridge idle. Configure it to enable. No-op."
  while true; do sleep 3600; done
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
if [ -d "$VAULT_DIR/.git" ] && ! git -C "$VAULT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  log "FATAL: $VAULT_DIR/.git exists but is not a usable git repository"
  log "       (an interrupted clone leaves this behind). Refusing to run against it:"
  log "       every operation would fail silently. Delete the directory to re-clone."
  exit 1
fi
if [ ! -d "$VAULT_DIR/.git" ]; then
  log "cloning vault -> $VAULT_DIR (branch $VAULT_BRANCH)"
  if ! mkdir -p "$(dirname "$VAULT_DIR")" 2>/dev/null; then
    log "FATAL: cannot create $(dirname "$VAULT_DIR") - is the data disk mounted and writable?"
    exit 1
  fi
  # Capture git's own stderr instead of discarding it. The generic guess-list
  # below is useful, but "Remote branch main not found" or "No space left on
  # device" is the actual answer, and it was being thrown away.
  clone_err="$(git clone --branch "$VAULT_BRANCH" "$VAULT_REPO" "$VAULT_DIR" 2>&1 >/dev/null)" || {
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

ensure_ob_setup() {
  if ob_q sync-status --path "$VAULT_DIR"; then
    return 0   # already linked
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
  # Conflict policy is a design law: match Sync's own end-to-end behaviour.
  # Sync's default strategy auto-merges concurrent device edits; forcing
  # `conflict` here would make the bridged experience WORSE than plain Sync
  # (conflict litter a Sync-only user never sees). Git history is the safety
  # net that makes merge safe: every pre-merge state is a commit.
  set -- sync-config --path "$VAULT_DIR" --conflict-strategy merge --mode bidirectional
  [ -n "$SYNC_CONFIGS" ] && set -- "$@" --configs "$SYNC_CONFIGS"
  ob_q "$@" || log "WARNING: sync-config failed (conflict strategy may default to merge)"
  return 0
}

# OB_PID is the real `ob` process, backgrounded directly - the same rule as
# INOTIFY_PID below, and for the same reason: a retry-loop wrapper subshell dies
# on SIGTERM while its `ob` child keeps running, orphaned. On a redeploy that
# means a dead deploy's Sync client still holds the vault - the exact two-writer
# situation this daemon exists to prevent. Restart-on-death happens inline in
# the main loop (rate-limited), never via a wrapper.
HAVE_OB=0
start_ob_continuous() {
  log "starting: ob sync --continuous --path $VAULT_DIR"
  ob sync --continuous --path "$VAULT_DIR" </dev/null \
    > >(sed "s/^/[ob:$NAME] /" >&2) 2>&1 &
  OB_PID=$!
}

if command -v ob >/dev/null 2>&1; then
  if ensure_ob_auth && ensure_ob_setup; then
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
      git -C "$VAULT_DIR" reset -q -- "$f" 2>/dev/null
      size_mb=$(( (size + 1048575) / 1048576 ))
      log "WARNING: $f exceeds sync cap (${size_mb} MB) - NOT committed; raise VAULT_MAX_FILE_MB or use LFS+exclusion deliberately"
    fi
  done
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
guard_mass_deletion() {
  [ "$MAX_DELETE_PCT" -gt 0 ] || return 0
  local deleted tracked pct
  deleted="$(git -C "$VAULT_DIR" diff --cached --name-only --diff-filter=D 2>/dev/null | wc -l)"
  [ "$deleted" -ge "$MIN_DELETE_FLOOR" ] || return 0
  tracked="$(git -C "$VAULT_DIR" ls-tree -r --name-only HEAD 2>/dev/null | wc -l)"
  [ "$tracked" -gt 0 ] || return 0
  pct=$(( deleted * 100 / tracked ))
  [ "$pct" -ge "$MAX_DELETE_PCT" ] || return 0
  log "REFUSING TO COMMIT: this pass would delete ${deleted} of ${tracked} tracked files (${pct}%)."
  log "         Nothing has been committed or pushed, and nothing in git is lost."
  log "         The working tree is left exactly as it is - inspect $VAULT_DIR."
  log "         If the deletion is intended: set VAULT_MAX_DELETE_PCT higher (or 0"
  log "         to disable this guard) and redeploy, or delete via a normal commit"
  log "         from a clone, which syncs without tripping this."
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
resolve_conflicts_sync_style() {
  local ts f base ext copy count=0
  ts="$(date -u '+%Y-%m-%d %H.%M.%S')"
  local dir fn made_copy
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
$(git -C "$VAULT_DIR" diff --name-only --diff-filter=U 2>/dev/null)
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
RECONCILE_ACTIVITY=0
reconcile_pass() {
  RECONCILE_ACTIVITY=0
  local before_rev after_rev

  # 1. Commit local changes FIRST. Device edits enter history before any merge
  #    can touch the tree, so no sequence of later steps can lose them - and
  #    `git merge` refuses a dirty tree anyway.
  if [ -n "$(git -C "$VAULT_DIR" status --porcelain 2>/dev/null || true)" ]; then
    git -C "$VAULT_DIR" add -A 2>/dev/null || true
    enforce_size_cap
    if ! guard_mass_deletion; then
      # The tree lost more than the allowed share of its notes. Refuse the whole
      # pass rather than committing it: unstage and leave the working tree
      # untouched, so the next pass re-evaluates. Nothing is deleted from git.
      git -C "$VAULT_DIR" reset -q 2>/dev/null || true
      return 0
    fi
    if ! git -C "$VAULT_DIR" diff --cached --quiet 2>/dev/null; then
      if git -C "$VAULT_DIR" commit -q -m "vault sync: $(date -u +%FT%TZ)" 2>/dev/null; then
        RECONCILE_ACTIVITY=1
      else
        # Every other failure in this loop logs; this one used to be silent, so a
        # full disk (the likeliest cause, and one a sibling vault can inflict on
        # a shared volume) looked exactly like a healthy idle daemon.
        log "WARNING: commit failed - changes remain uncommitted (disk full? index lock?)."
      fi
    fi
  fi

  # 2. Fetch, then reconcile with the remote: fast-forward when possible, a
  #    real merge when diverged (matching Sync's own auto-merge semantics),
  #    Sync-style conflicted copies when the merge genuinely collides.
  before_rev="$(git -C "$VAULT_DIR" rev-parse HEAD 2>/dev/null || true)"
  if git_net fetch origin "$VAULT_BRANCH" >/dev/null 2>&1; then
    if ! git -C "$VAULT_DIR" merge-base --is-ancestor "origin/$VAULT_BRANCH" HEAD 2>/dev/null; then
      if ! git -C "$VAULT_DIR" merge --no-edit "origin/$VAULT_BRANCH" >/dev/null 2>&1; then
        if ! resolve_conflicts_sync_style; then
          git -C "$VAULT_DIR" merge --abort >/dev/null 2>&1 || true
          log "WARNING: merge failed and conflicted-copy resolution also failed -"
          log "         leaving tree as-is (retrying next pass; never force-pushing)."
        fi
      fi
    fi
  fi
  after_rev="$(git -C "$VAULT_DIR" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$after_rev" ] && [ "$after_rev" != "$before_rev" ] && RECONCILE_ACTIVITY=1

  # 3. Push whatever is now ahead of the remote.
  if ! git -C "$VAULT_DIR" merge-base --is-ancestor HEAD "origin/$VAULT_BRANCH" 2>/dev/null; then
    git_net push origin "$VAULT_BRANCH" >/dev/null 2>&1 \
      || log "push failed (retrying next pass; never force-pushing)."
  fi
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
  if [ "$HAVE_INOTIFY" -eq 1 ] && ! kill -0 "$INOTIFY_PID" 2>/dev/null; then
    log "WARNING: inotifywait died - restarting watch"
    start_inotify_watch
  fi

  # ob restart-on-death, rate-limited to one attempt per 5s so a fast-crashing
  # ob (bad credentials revoked mid-run, say) cannot busy-loop the daemon.
  if [ "$HAVE_OB" -eq 1 ] && ! kill -0 "$OB_PID" 2>/dev/null; then
    now_ts="$(date +%s)"
    if [ "$now_ts" -ge "$OB_RESTART_AFTER" ]; then
      log "WARNING: ob sync exited - restarting"
      start_ob_continuous
      OB_RESTART_AFTER=$(( now_ts + 5 ))
    fi
  fi

  triggered_by_event=0
  if [ "$HAVE_INOTIFY" -eq 1 ]; then
    if read -r -t "$CURRENT_INTERVAL" -u 3 _line; then
      triggered_by_event=1
      debounce_drain
    fi
  else
    sleep "$CURRENT_INTERVAL"
  fi

  reconcile_pass

  if [ "$triggered_by_event" -eq 1 ] || [ "$RECONCILE_ACTIVITY" -eq 1 ]; then
    LAST_ACTIVITY="$(date +%s)"
  fi
  update_interval
done

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
OB_TIMEOUT="${VAULT_OB_TIMEOUT:-300}"
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
# `ob sync --continuous` narrates its own work ("Connecting", "Detecting
# changes", "Fully synced"). That stream was prefixed and discarded, which is
# why an ob that stayed ALIVE but stopped syncing was undetectable: kill -0 only
# proves the process exists. Stamping a marker on every line it emits turns its
# own narration into a liveness signal - the closest thing to a heartbeat the
# client offers, since there is no health API to ask.
#
# The marker lives beside the sync state, NEVER inside VAULT_DIR: a file in the
# vault would be committed and synced to every device.
OB_ACTIVITY_FILE="${XDG_CONFIG_HOME:-/tmp}/ob-activity-$NAME"
start_ob_continuous() {
  log "starting: ob sync --continuous --path $VAULT_DIR"
  touch "$OB_ACTIVITY_FILE" 2>/dev/null || true
  ob sync --continuous --path "$VAULT_DIR" </dev/null \
    > >(while IFS= read -r _ob_line; do
          touch "$OB_ACTIVITY_FILE" 2>/dev/null || true
          printf '[ob:%s] %s\n' "$NAME" "$_ob_line" >&2
        done) 2>&1 &
  OB_PID=$!
}

# Seconds of total ob silence that count as "probably not syncing". ob narrates
# in bursts with long quiet gaps between them, so this has to sit comfortably
# above the observed gap rather than at it. 0 disables the check.
OB_SILENCE_WARN="${VAULT_OB_SILENCE_WARN:-5400}"
ob_silence_secs() {
  [ -f "$OB_ACTIVITY_FILE" ] || { printf 'unknown'; return; }
  local last now
  last="$(stat -c %Y "$OB_ACTIVITY_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  printf '%s' "$(( now - last ))"
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
        # Log the first failure, then rarely: this fires once per poll while the
        # underlying condition lasts, and unbounded spam buries the message that
        # matters.
        COMMIT_FAIL_COUNT=$(( COMMIT_FAIL_COUNT + 1 ))
        if [ "$COMMIT_FAIL_COUNT" -eq 1 ] || [ $(( COMMIT_FAIL_COUNT % 60 )) -eq 0 ]; then
          log "WARNING: commit failed (x${COMMIT_FAIL_COUNT}) - changes remain uncommitted (disk full? index lock?)."
        fi
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
      log "heartbeat: HEAD=$hb_head uncommitted=$hb_dirty poll=${CURRENT_INTERVAL}s ob=${HAVE_OB} ob_quiet=${hb_obq}s"
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
    sleep "$CURRENT_INTERVAL"
  fi

  reconcile_pass

  if [ "$triggered_by_event" -eq 1 ] || [ "$RECONCILE_ACTIVITY" -eq 1 ]; then
    LAST_ACTIVITY="$(date +%s)"
  fi
  update_interval
done

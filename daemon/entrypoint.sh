#!/usr/bin/env bash
# =============================================================================
# vault-bridge entrypoint - discover vaults, supervise one bridge per vault.
# =============================================================================
# There is NO manifest. A vault is enabled by the existence of its config:
#
#   1. Env-group mode (multi-vault, fully env-driven): VAULTS is a comma list of
#      vault names ("planning,personal"); each vault's keys are namespaced env
#      vars VAULT_<NAME>_REPO / _BRANCH / _SYNC_REMOTE /
#      _SYNC_ENCRYPTION_PASSWORD / _SYNC_CONFIGS / _DEVICE_NAME / _MAX_FILE_MB
#      (name uppercased, "-" becomes "_"). One Render env group can therefore
#      define the entire service with zero secret files. Takes precedence over
#      secret files when set.
#
#   2. Secret-file mode (multi-vault): every $SECRETS_DIR/vault-<name>.env is a
#      vault. `vault-planning.env` => vault "planning". Adding a vault is adding
#      a file; removing one is removing a file.
#
#   3. Plain-env mode (single vault): neither of the above, but VAULT_REPO set
#      => one vault named $VAULT_NAME (default "planning").
#
# Shared, non-per-vault keys stay plain in every mode: OBSIDIAN_AUTH_TOKEN and
# GIT_TOKEN apply to all vaults (one Obsidian account, one PAT).
#
# Sync state (auth token + per-vault state.db) lives in ONE shared
# XDG_CONFIG_HOME on the persistent disk. obsidian-headless already namespaces
# per vault underneath it as sync/<vault>/state.db, so separate homes per vault
# would be redundant - and losing this directory forces a full re-sync, which is
# why it must be on the disk and never inside a vault's git tree.
# =============================================================================
set -u

SECRETS_DIR="${SECRETS_DIR:-/etc/secrets}"
DATA_DIR="${DATA_DIR:-/data}"
BRIDGE_BIN="${BRIDGE_BIN:-/app/bridge.sh}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$DATA_DIR/ob-state}"

log() { printf '[vault-bridge] %s\n' "$*" >&2; }

mkdir -p "$XDG_CONFIG_HOME" 2>/dev/null || true
if ! [ -w "$XDG_CONFIG_HOME" ]; then
  log "FATAL: XDG_CONFIG_HOME=$XDG_CONFIG_HOME is not writable. A persistent disk must be mounted at $DATA_DIR."
  exit 1
fi
log "sync state: $XDG_CONFIG_HOME (must be on a persistent disk)"

PIDS=""
trap 'log "shutting down"; for p in $PIDS; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null; exit 0' INT TERM

# supervise <name> <secret-file-or-empty>
# Restart-with-backoff so one vault's failure never takes the others down.
#
# SIGNAL FORWARDING IS LOAD-BEARING. The retry-loop subshell backgrounds its
# bridge child and forwards INT/TERM to it explicitly. Without that, killing
# the subshell leaves the bridge orphaned on PID 1, still committing and
# pushing - so a redeploy would run TWO daemons against one vault repo. This
# was observed, not theorised: an orphaned bridge kept pushing edits after its
# supervisor logged "shutting down". (Dockerfile's `tini -g` signals the whole
# process group as a second line of defence; this forwarding must hold even
# without tini, e.g. under a bare `docker run --init=false` or in tests.)
supervise() {
  local name="$1" secret="$2" mode="${3:-file}"
  (
    delay=5; child=""
    trap '[ -n "$child" ] && kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' INT TERM
    while true; do
      (
        if [ "$mode" != "plain" ]; then
          # Per-vault keys must come from THIS vault's config only. Inheriting
          # them from the container environment would silently point every vault
          # at one repo/dir and corrupt their sync state into each other.
          unset VAULT_DIR VAULT_REPO VAULT_BRANCH VAULT_SYNC_REMOTE \
                VAULT_SYNC_ENCRYPTION_PASSWORD VAULT_SYNC_CONFIGS \
                VAULT_DEVICE_NAME VAULT_MAX_FILE_MB
        fi
        if [ "$mode" = "file" ] && [ -n "$secret" ]; then
          set -a
          # shellcheck disable=SC1090
          [ -r "$secret" ] && . "$secret"
          set +a
        elif [ "$mode" = "envmap" ]; then
          # VAULT_<NAME>_<KEY> -> VAULT_<KEY>, name uppercased, "-" -> "_".
          U="$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
          for k in REPO BRANCH SYNC_REMOTE SYNC_ENCRYPTION_PASSWORD \
                   SYNC_CONFIGS DEVICE_NAME MAX_FILE_MB; do
            src="VAULT_${U}_${k}"
            if [ -n "${!src:-}" ]; then
              export "VAULT_${k}=${!src}"
            fi
          done
        fi
        export VAULT_NAME="$name"
        export VAULT_DIR="${VAULT_DIR:-$DATA_DIR/vaults/$name}"
        exec "$BRIDGE_BIN"
      ) &
      child=$!
      wait "$child"   # interruptible: the trap above fires mid-wait
      log "vault '$name' exited - restarting in ${delay}s"
      sleep "$delay" &
      child=$!        # forward a shutdown arriving mid-backoff too
      wait "$child"
      delay=$(( delay < 120 ? delay * 2 : 120 ))
    done
  ) &
  PIDS="$PIDS $!"
  log "supervising vault '$name'${secret:+ (from $(basename "$secret"))}"
}

found=0
if [ -n "${VAULTS:-}" ]; then
  old_ifs="$IFS"; IFS=','
  # shellcheck disable=SC2086
  set -- $VAULTS
  IFS="$old_ifs"
  for name in "$@"; do
    name="${name// /}"
    [ -n "$name" ] || continue
    # Catch a HALF-ADDED vault at boot, loudly: a name in VAULTS whose repo key
    # is missing is a config mistake, not an intentional idle. The commonest
    # cause is forgetting that adding a vault has THREE parts: the env keys,
    # extending GIT_TOKEN to the new repo (fine-grained PATs enumerate
    # repositories explicitly - a new repo is NEVER covered automatically),
    # and the new vault's E2E password if its Sync remote is encrypted.
    U="$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
    rv="VAULT_${U}_REPO"
    if [ -z "${!rv:-}" ]; then
      log "WARNING: vault '$name' is HALF-ADDED - listed in VAULTS but $rv is unset."
      log "         Set $rv, extend GIT_TOKEN to cover the new repo, and set"
      log "         VAULT_${U}_SYNC_ENCRYPTION_PASSWORD if its Sync remote is encrypted."
      log "         Its bridge will idle until then."
    fi
    supervise "$name" "" envmap
    found=$((found + 1))
  done
fi

if [ "$found" -eq 0 ]; then
  for f in "$SECRETS_DIR"/vault-*.env; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"; name="${base#vault-}"; name="${name%.env}"
    supervise "$name" "$f" file
    found=$((found + 1))
  done
fi

if [ "$found" -eq 0 ]; then
  if [ -n "${VAULT_REPO:-}" ]; then
    supervise "${VAULT_NAME:-planning}" "" plain
    found=1
  else
    log "No VAULTS list, no $SECRETS_DIR/vault-*.env, no VAULT_REPO - nothing to do."
    log "Idling so the service stays healthy; add config and redeploy."
    while true; do sleep 3600; done
  fi
fi

log "$found vault(s) running"
wait

#!/usr/bin/env bash
# =============================================================================
# vault-bridge entrypoint - discover vaults, supervise one bridge per vault.
# =============================================================================
# There is NO manifest. A vault is enabled by the existence of its config:
#
#   1. Env-group mode (multi-vault, fully env-driven): VAULT_1, VAULT_2, ... are
#      the identifier variables, each holding the vault's git repo URL - the
#      repo IS the vault's identity (git is the source of truth). Per-vault
#      settings are VAULT_<n>_BRANCH / _SYNC_REMOTE / _SYNC_ENCRYPTION_PASSWORD
#      / _SYNC_CONFIGS / _DEVICE_NAME / _MAX_FILE_MB / _NAME. The local name
#      (working dir, log prefix, sync-state key) derives from the repo basename
#      lowercased ("PlanningVault.git" -> "planningvault"); _NAME overrides.
#      Indices may have gaps - deleting VAULT_2 never requires renumbering
#      VAULT_3. One Render env group defines the whole service with zero secret
#      files. Takes precedence over secret files when any VAULT_<n> is set.
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
        elif [ "$mode" = "indexed" ]; then
          # secret carries the index. VAULT_<n> is the repo; VAULT_<n>_<KEY>
          # maps to VAULT_<KEY>.
          idx="$secret"
          src="VAULT_${idx}"
          export "VAULT_REPO=${!src}"
          for k in BRANCH SYNC_REMOTE SYNC_ENCRYPTION_PASSWORD \
                   SYNC_CONFIGS DEVICE_NAME MAX_FILE_MB; do
            src="VAULT_${idx}_${k}"
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

# Derive the vault's local name from its repo URL: basename, minus .git,
# lowercased, non [a-z0-9_-] squeezed to '-'. The repo is the identity; the
# name is only a local label (working dir, log prefix, sync-state key).
derive_name() {
  local base="${1%%\?*}"
  base="${base%/}"; base="${base##*/}"; base="${base%.git}"
  printf '%s' "$base" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-' | sed 's/-*$//;s/^-*//'
}

found=0
SEEN_NAMES=" "  # space-delimited set of derived names, for collision detection
# Indexed env-group mode: scan a bounded index space, tolerating gaps so that
# deleting VAULT_2 never forces renumbering VAULT_3.
for idx in $(seq 1 64); do
  rv="VAULT_${idx}"
  [ -n "${!rv:-}" ] || continue
  nv="VAULT_${idx}_NAME"
  # Scrub the override through the same rule as a derived name: the name is only
  # a local label (working dir, log prefix, state key), so an explicit
  # VAULT_n_NAME of "../ob-state" must not escape $DATA_DIR/vaults/ and point the
  # working tree at the auth-token store. derive_name squeezes everything outside
  # [a-z0-9_-], so '/' and '.' cannot survive.
  name="$(derive_name "${!nv:-$(derive_name "${!rv}")}")"
  if [ -z "$name" ]; then
    log "WARNING: VAULT_${idx} is set but no vault name could be derived - skipping."
    continue
  fi
  # Refuse a duplicate derived name rather than collapsing two repos onto one
  # working dir + one Sync state.db (two writers, silent corruption). The repo is
  # the identity; two repos with a colliding basename need an explicit
  # VAULT_n_NAME to tell them apart.
  case "$SEEN_NAMES" in
    *" $name "*)
      log "FATAL: VAULT_${idx} derives the name '$name', already used by another vault."
      log "       Two vaults sharing a local name would collapse onto one working"
      log "       tree and one sync state - set a distinct VAULT_${idx}_NAME. Skipping."
      continue ;;
  esac
  SEEN_NAMES="$SEEN_NAMES$name "
  supervise "$name" "$idx" indexed
  found=$((found + 1))
done

# Catch HALF-ADDED vaults loudly: VAULT_<n>_<sub> keys whose VAULT_<n>
# identifier is missing are a config mistake, not an intentional idle. The
# commonest cause is forgetting that adding a vault has THREE parts: the env
# keys, extending GIT_TOKEN to the new repo (fine-grained PATs enumerate
# repositories explicitly - a new repo is NEVER covered automatically), and
# the vault's E2E password if its Sync remote is encrypted.
for orphan in $(env | grep -o '^VAULT_[0-9]*_' | sed 's/^VAULT_//;s/_$//' | sort -u); do
  rv="VAULT_${orphan}"
  if [ -z "${!rv:-}" ]; then
    log "WARNING: vault #${orphan} is HALF-ADDED - VAULT_${orphan}_* keys exist but"
    log "         VAULT_${orphan} (the repo URL, the vault's identity) is unset."
    log "         Set it, extend GIT_TOKEN to cover the repo, and set"
    log "         VAULT_${orphan}_SYNC_ENCRYPTION_PASSWORD if the Sync remote is encrypted."
  fi
done

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

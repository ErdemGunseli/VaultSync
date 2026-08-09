#!/usr/bin/env bash
# =============================================================================
# vault-bridge entrypoint - discover vaults, supervise one bridge per vault.
# =============================================================================
# There is NO manifest. A vault is enabled by the existence of its config:
#
#   1. Secret-file mode (multi-vault): every $SECRETS_DIR/vault-<name>.env is a
#      vault. `vault-planning.env` => vault "planning". Adding a vault is adding
#      a file; removing one is removing a file. Nothing else to keep in sync.
#
#   2. Plain-env mode (single vault): no secret files, but VAULT_REPO set in the
#      environment => one vault named $VAULT_NAME (default "planning"). This is
#      the simple path on a host where plain env vars are easier than files.
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
supervise() {
  local name="$1" secret="$2" delay=5
  (
    while true; do
      (
        if [ -n "$secret" ]; then
          # Per-vault keys must come from THIS vault's file only. Inheriting them
          # from the container environment would silently point every vault at
          # one repo/dir and corrupt their sync state into each other.
          unset VAULT_DIR VAULT_REPO VAULT_SYNC_REMOTE VAULT_SYNC_ENCRYPTION_PASSWORD
          set -a
          # shellcheck disable=SC1090
          [ -r "$secret" ] && . "$secret"
          set +a
        fi
        export VAULT_NAME="$name"
        export VAULT_DIR="${VAULT_DIR:-$DATA_DIR/vaults/$name}"
        exec "$BRIDGE_BIN"
      )
      log "vault '$name' exited - restarting in ${delay}s"
      sleep "$delay"
      delay=$(( delay < 120 ? delay * 2 : 120 ))
    done
  ) &
  PIDS="$PIDS $!"
  log "supervising vault '$name'${secret:+ (from $(basename "$secret"))}"
}

found=0
for f in "$SECRETS_DIR"/vault-*.env; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"; name="${base#vault-}"; name="${name%.env}"
  supervise "$name" "$f"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  if [ -n "${VAULT_REPO:-}" ]; then
    supervise "${VAULT_NAME:-planning}" ""
    found=1
  else
    log "No $SECRETS_DIR/vault-*.env and no VAULT_REPO - nothing to do."
    log "Idling so the service stays healthy; add config and redeploy."
    while true; do sleep 3600; done
  fi
fi

log "$found vault(s) running"
wait

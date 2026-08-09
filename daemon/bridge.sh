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
#   - Conflict policy: SURFACE, never rewrite. pull --ff-only; never force-push;
#     `ob sync-config --conflict-strategy conflict` so Sync writes conflict files
#     rather than silently merging.
#   - Fail-soft: unset VAULT_REPO idles; missing/unauthenticated ob degrades to
#     git-only with a WARNING rather than crash-looping.
#   - NOTHING may block on a prompt. Every `ob` call redirects stdin from
#     /dev/null so a missing credential fails fast instead of hanging forever.
#
# ENV (see secrets.example/vault-planning.env):
#   VAULT_NAME                        logical name (log prefix, sync state key)
#   VAULT_REPO                        git URL incl. push auth (unset => idle)
#   VAULT_DIR                         working tree (default /data/vaults/<name>)
#   VAULT_BRANCH                      branch (default main)
#   VAULT_BRIDGE_INTERVAL             seconds between git passes (default 15)
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
INTERVAL="${VAULT_BRIDGE_INTERVAL:-15}"
SYNC_REMOTE="${VAULT_SYNC_REMOTE:-}"
SYNC_ENC_PW="${VAULT_SYNC_ENCRYPTION_PASSWORD:-}"
SYNC_CONFIGS="${VAULT_SYNC_CONFIGS:-}"
DEVICE_NAME="${VAULT_DEVICE_NAME:-vault-bridge-$NAME}"
GIT_NAME="${GIT_AUTHOR_NAME:-vault-bridge}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-vault-bridge@localhost}"
OB_PID=""

log() { printf '[vault-bridge:%s] %s\n' "$NAME" "$*" >&2; }

# `ob` must never inherit a TTY or a readable stdin: a prompt in a background
# worker hangs forever and is invisible. Fail fast instead.
ob_q() { ob "$@" </dev/null >/dev/null 2>&1; }
ob_v() { ob "$@" </dev/null; }

cleanup() {
  if [ -n "$OB_PID" ] && kill -0 "$OB_PID" 2>/dev/null; then
    kill "$OB_PID" 2>/dev/null || true
    wait "$OB_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# --- 0. Unconfigured => idle without error -----------------------------------
if [ -z "$VAULT_REPO" ]; then
  log "VAULT_REPO unset - bridge idle. Configure it to enable. No-op."
  while true; do sleep 3600; done
fi

command -v git >/dev/null 2>&1 || { log "FATAL: git not installed"; exit 1; }
HAVE_LFS=0
if command -v git-lfs >/dev/null 2>&1; then
  HAVE_LFS=1
  git lfs install --skip-repo >/dev/null 2>&1 || log "WARNING: git-lfs install failed (media may not sync)"
fi

# --- 1. Ensure the vault clone exists ----------------------------------------
if [ ! -d "$VAULT_DIR/.git" ]; then
  log "cloning vault -> $VAULT_DIR (branch $VAULT_BRANCH)"
  mkdir -p "$(dirname "$VAULT_DIR")" 2>/dev/null || true
  if ! git clone --branch "$VAULT_BRANCH" "$VAULT_REPO" "$VAULT_DIR" 2>/dev/null; then
    log "FATAL: clone failed (auth? branch? network?). Not retrying blindly."
    exit 1
  fi
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
  # Conflict policy is a design law: surface conflicts, never silently merge.
  set -- sync-config --path "$VAULT_DIR" --conflict-strategy conflict --mode bidirectional
  [ -n "$SYNC_CONFIGS" ] && set -- "$@" --configs "$SYNC_CONFIGS"
  ob_q "$@" || log "WARNING: sync-config failed (conflict strategy may default to merge)"
  return 0
}

start_ob_continuous() {
  log "starting: ob sync --continuous --path $VAULT_DIR"
  (
    while true; do
      ob sync --continuous --path "$VAULT_DIR" </dev/null 2>&1 | sed "s/^/[ob:$NAME] /" >&2
      log "ob sync exited - restarting in 5s"
      sleep 5
    done
  ) &
  OB_PID=$!
}

if command -v ob >/dev/null 2>&1; then
  if ensure_ob_auth && ensure_ob_setup; then
    start_ob_continuous
  else
    log "WARNING: device<->bridge Sync DISABLED (git-only mode). Agent edits still sync; phone-only edits will NOT."
  fi
else
  log "WARNING: 'ob' not installed - device sync DISABLED (git-only mode)."
fi

# --- 3. Reconcile loop -------------------------------------------------------
log "reconcile loop every ${INTERVAL}s on branch ${VAULT_BRANCH}"
while true; do
  if ! git -C "$VAULT_DIR" pull --ff-only origin "$VAULT_BRANCH" >/dev/null 2>&1; then
    log "pull not fast-forward (diverged or offline) - leaving tree as-is (SURFACING, not rewriting)."
  fi
  # Obsidian Sync writes its own conflict copies into the tree. They are the
  # SURFACING mechanism, so announce them loudly rather than letting them slide
  # into history unremarked - the vault's .gitignore (see vault.gitignore.example)
  # is what keeps them out of the commit.
  conflicts="$(git -C "$VAULT_DIR" status --porcelain 2>/dev/null \
    | grep -Ei 'sync-conflict|conflicted copy' | head -5 || true)"
  if [ -n "$conflicts" ]; then
    log "CONFLICT: Obsidian Sync wrote conflict copies - a human must reconcile these:"
    printf '%s\n' "$conflicts" | while IFS= read -r c; do log "  $c"; done
  fi

  if [ -n "$(git -C "$VAULT_DIR" status --porcelain 2>/dev/null || true)" ]; then
    git -C "$VAULT_DIR" add -A 2>/dev/null || true
    if ! git -C "$VAULT_DIR" diff --cached --quiet 2>/dev/null; then
      if git -C "$VAULT_DIR" commit -q -m "vault sync: $(date -u +%FT%TZ)" 2>/dev/null; then
        git -C "$VAULT_DIR" push origin "$VAULT_BRANCH" >/dev/null 2>&1 \
          || log "push failed (retrying next pass; never force-pushing)."
      fi
    fi
  fi
  sleep "$INTERVAL"
done

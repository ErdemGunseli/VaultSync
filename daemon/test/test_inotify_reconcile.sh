#!/usr/bin/env bash
# Behavioural tests for the event-driven fast path: inotify-triggered commits,
# debounce under continuous writes, and the fail-soft fallback when
# inotifywait is unavailable.
#
# Runs the real bridge.sh against real git repos, same style as
# test_git_reconcile.sh. Nothing here greps the source.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$HERE/../bridge.sh"
PASS=0; FAIL=0
# Isolate from the host's git config. NOT /dev/null: git >=2.43 parses a config
# path as a real file and errors "bad config line 1 in file /dev/null", which
# made every git-touching assertion in this suite fail for environmental
# reasons. An empty regular file is the portable isolation.
GIT_ISOLATED_CONFIG="$(mktemp)"
export GIT_CONFIG_GLOBAL="$GIT_ISOLATED_CONFIG" GIT_CONFIG_SYSTEM="$GIT_ISOLATED_CONFIG"

check() {
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1))
  else printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

skip() { printf 'skip - %s (%s)\n' "$1" "$2"; }

await() {
  local secs="$1"; shift
  local i=0
  while [ "$i" -lt "$((secs * 2))" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

setup_remote() {
  local tmp="$1"
  git init -q --bare "$tmp/remote.git"
  git init -q "$tmp/seed" && (
    cd "$tmp/seed"
    git config user.email t@t.invalid && git config user.name t
    echo "hello" > note.md && git add -A && git commit -qm init
    git branch -M main && git remote add origin "$tmp/remote.git" && git push -q origin main
  )
  git -C "$tmp/remote.git" symbolic-ref HEAD refs/heads/main
}

if ! command -v inotifywait >/dev/null 2>&1; then
  skip "fast path: local edit committed well under the 15s legacy interval" "inotifywait not installed"
  skip "debounce: a burst of continuous writes yields at most 2 commits" "inotifywait not installed"
else
  # --- fast path: an edit is committed+pushed well under 15s -----------------
  TMP="$(mktemp -d)"
  trap 'kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP"' EXIT
  setup_remote "$TMP"

  # No VAULT_BRIDGE_INTERVAL override here - the fast commit must come from the
  # inotify event path, not from a short legacy poll masquerading as fast.
  env VAULT_NAME=fast \
      VAULT_REPO="$TMP/remote.git" \
      VAULT_DIR="$TMP/vault" \
      VAULT_BRANCH=main \
      VAULT_MAX_FILE_MB=5 \
      XDG_CONFIG_HOME="$TMP/obstate" \
      bash "$BRIDGE" > "$TMP/log" 2>&1 &
  BRIDGE_PID=$!

  await 20 test -f "$TMP/vault/note.md"
  check "bridge clones before the fast-path write" "0" "$?"

  start_ts="$(date +%s)"
  echo "typed by a device" > "$TMP/vault/fast-note.md"
  remote_has() { git -C "$TMP/remote.git" show "main:fast-note.md" >/dev/null 2>&1; }
  await 8 remote_has
  rc=$?
  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))
  check "inotify-triggered edit reaches the remote" "0" "$rc"
  check "commit latency is well under the old 15s poll" "yes" "$([ "$elapsed" -lt 8 ] && echo yes || echo no)"

  check "inotify path is announced in the log" "yes" \
    "$(grep -q 'inotify=1' "$TMP/log" && echo yes || echo no)"

  kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null
  rm -rf "$TMP"
  trap - EXIT

  # --- debounce: continuous writes for ~3s produce at most 2 commits ---------
  TMP="$(mktemp -d)"
  trap 'kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP"' EXIT
  setup_remote "$TMP"

  env VAULT_NAME=debounce \
      VAULT_REPO="$TMP/remote.git" \
      VAULT_DIR="$TMP/vault" \
      VAULT_BRANCH=main \
      VAULT_MAX_FILE_MB=5 \
      XDG_CONFIG_HOME="$TMP/obstate" \
      bash "$BRIDGE" > "$TMP/log" 2>&1 &
  BRIDGE_PID=$!

  await 20 test -f "$TMP/vault/note.md"
  check "bridge clones before the debounce write burst" "0" "$?"

  base_commits="$(git -C "$TMP/remote.git" log --oneline main | wc -l | tr -d ' ')"

  # Obsidian saves on every keystroke - simulate that: write the same file
  # every ~0.2s for ~3s, well inside the 5s debounce cap.
  end=$(( $(date +%s%N) / 1000000 + 3000 ))
  n=0
  while [ "$(( $(date +%s%N) / 1000000 ))" -lt "$end" ]; do
    n=$((n + 1))
    echo "keystroke $n" > "$TMP/vault/typing.md"
    sleep 0.2
  done

  # Give the debounce quiet-period + one reconcile pass time to land.
  sleep 4
  after_commits="$(git -C "$TMP/remote.git" log --oneline main | wc -l | tr -d ' ')"
  new_commits=$((after_commits - base_commits))
  check "continuous writes for ~3s produce at most 2 commits, not one per write" "yes" \
    "$([ "$new_commits" -ge 1 ] && [ "$new_commits" -le 2 ] && echo yes || echo "no ($new_commits commits)")"

  kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null
  rm -rf "$TMP"
  trap - EXIT
fi

# --- fallback: no inotifywait on PATH -> interval-only polling, WARNING ----
TMP="$(mktemp -d)"
trap 'kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP"' EXIT
setup_remote "$TMP"

# Build a PATH with every real tool except inotifywait, so the bridge's own
# `command -v inotifywait` check genuinely fails, exercising the fallback for
# real rather than asserting on a mocked flag.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
for tool in git git-lfs bash sh date grep sed printf mkdir rm cat head tr wc mktemp stat kill sleep timeout env find dirname basename ln; do
  p="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$FAKEBIN/$tool"
done

# PATH is ONLY the curated fakebin (no /usr/bin, where inotifywait really
# lives in this container) - this exercises the real `command -v inotifywait`
# check failing, not a mocked substitute for it.
env -i PATH="$FAKEBIN" \
    VAULT_NAME=fallback \
    VAULT_REPO="$TMP/remote.git" \
    VAULT_DIR="$TMP/vault" \
    VAULT_BRANCH=main \
    VAULT_BRIDGE_INTERVAL=2 \
    XDG_CONFIG_HOME="$TMP/obstate" \
    HOME="$TMP" \
    bash "$BRIDGE" > "$TMP/log" 2>&1 &
BRIDGE_PID=$!

await 20 test -f "$TMP/vault/note.md"
check "bridge still clones without inotifywait on PATH" "0" "$?"

echo "written while degraded" > "$TMP/vault/fallback-note.md"
remote_has() { git -C "$TMP/remote.git" show "main:fallback-note.md" >/dev/null 2>&1; }
await 15 remote_has
check "edit still reaches the remote via interval polling" "0" "$?"

check "missing inotifywait is warned about" "1" "$(grep -c "inotifywait' not installed" "$TMP/log")"
check "fallback never claims the inotify path is active" "0" "$(grep -c 'inotify=1' "$TMP/log")"

kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null
rm -rf "$TMP"
trap - EXIT

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

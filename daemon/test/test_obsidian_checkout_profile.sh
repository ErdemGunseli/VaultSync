#!/usr/bin/env bash
# Real Git checkout/index/merge behavior. Every note and origin is disposable.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; BRIDGE="${BRIDGE_UNDER_TEST:-$HERE/../bridge.sh}"
LAB="$(mktemp -d)"; LAB="$(cd "$LAB" && pwd -P)"
PID=""; PASS=0; FAIL=0; SLOT=vault; PROFILE=obsidian; LEGACY=0; REPO="$LAB/remote.git"
cleanup() { [ -z "$PID" ] || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }; rm -rf "$LAB"; }
trap cleanup EXIT
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); else printf 'FAIL - %s: expected %s got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
await() { local n=0; while [ "$n" -lt 60 ]; do "$@" >/dev/null 2>&1 && return; sleep .1; n=$((n+1)); done; return 1; }
export GIT_CONFIG_GLOBAL="$LAB/gitconfig" GIT_CONFIG_SYSTEM="$LAB/gitconfig"
: > "$LAB/gitconfig"
git init -q --bare "$LAB/remote.git"; git init -q "$LAB/seed"
git -C "$LAB/seed" config user.name fixture; git -C "$LAB/seed" config user.email fixture@example.invalid
mkdir -p "$LAB/seed/.agent-memory" "$LAB/seed/.sources" "$LAB/seed/Course One/.sources" \
  "$LAB/seed/.obsidian/plugins/.internal" "$LAB/seed/Odd/.gitattributes"
printf 'visible note\n' > "$LAB/seed/note.md"
printf 'nested visible\n' > "$LAB/seed/Course One/visible note.md"
printf 'data\n' > "$LAB/seed/Course One/visible.data"
printf '*.tmp\n' > "$LAB/seed/.gitignore"
printf '*.data bridge-probe=root\n' > "$LAB/seed/.gitattributes"
printf '*.data bridge-probe=nested\n' > "$LAB/seed/Course One/.gitattributes"
printf '*.part* bridge-probe=archive\n' > "$LAB/seed/Course One/.sources/.gitattributes"
printf '*.tmp\n' > "$LAB/seed/Course One/.sources/.gitignore"
printf 'root archive\n' > "$LAB/seed/.sources/archive.zip"
printf 'recording archive\n' > "$LAB/seed/Course One/.sources/recording.zip.part001"
printf 'bookkeeping\n' > "$LAB/seed/.agent-memory/audit.md"
printf 'lookalike directory archive\n' > "$LAB/seed/Odd/.gitattributes/archive.zip"
printf 'config\n' > "$LAB/seed/.obsidian/plugins/.internal/config.json"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm seed; git -C "$LAB/seed" branch -M main
git -C "$LAB/seed" remote add origin "$LAB/remote.git"; git -C "$LAB/seed" push -qu origin main
git -C "$LAB/remote.git" symbolic-ref HEAD refs/heads/main
start() {
  env VAULT_NAME=profile VAULT_REPO="$REPO" VAULT_DIR="$LAB/$SLOT" \
    XDG_CONFIG_HOME="$LAB/state" VAULT_HEALTH_DIR="$LAB/health-$SLOT" \
    VAULT_CHECKOUT_PROFILE="$PROFILE" VAULT_EXCLUDE_AGENT_MEMORY="$LEGACY" \
    VAULT_BRIDGE_INTERVAL=.2 VAULT_HEARTBEAT_SECS=0 \
    bash "$BRIDGE" > "$LAB/log-$SLOT" 2>&1 & PID=$!
}
stop() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; PID=""; }
remote_has() { git -C "$LAB/remote.git" cat-file -e "main:$1"; }
present() { [ -f "$LAB/$SLOT/$1" ]; }
absent() { [ ! -e "$LAB/$SLOT/$1" ]; }
clone_slot() { SLOT="$1"; git clone -q "$LAB/remote.git" "$LAB/$SLOT"; git -C "$LAB/$SLOT" config user.name fixture; git -C "$LAB/$SLOT" config user.email fixture@example.invalid; }
refused() { grep -q 'sparse exclusion refused' "$LAB/log-$SLOT"; }

start
await present note.md || true
check 'initial sparse checkout includes visible root content' yes "$(present note.md && echo yes || echo no)"
check 'visible nested paths with spaces remain' yes "$(present 'Course One/visible note.md' && echo yes || echo no)"
check 'root hidden archive is omitted' yes "$(absent .sources/archive.zip && echo yes || echo no)"
check 'nested hidden recording archive is omitted' yes "$(absent 'Course One/.sources/recording.zip.part001' && echo yes || echo no)"
check 'root agent-only bookkeeping is omitted' yes "$(absent .agent-memory/audit.md && echo yes || echo no)"
check 'hidden config descendants under root Obsidian folder remain' yes "$(present .obsidian/plugins/.internal/config.json && echo yes || echo no)"
check 'root Git ignore/attribute files remain' yes "$([ -f "$LAB/vault/.gitignore" ] && [ -f "$LAB/vault/.gitattributes" ] && echo yes || echo no)"
check 'nested Git attribute file remains' yes "$(present 'Course One/.gitattributes' && echo yes || echo no)"
check 'Git attribute/ignore files inside hidden parents remain' yes "$([ -f "$LAB/vault/Course One/.sources/.gitattributes" ] && [ -f "$LAB/vault/Course One/.sources/.gitignore" ] && echo yes || echo no)"
check 'similarly named hidden directories do not include archives' yes "$(absent Odd/.gitattributes/archive.zip && echo yes || echo no)"
check 'nested attribute precedence is intact' nested "$(git -C "$LAB/vault" check-attr bridge-probe -- 'Course One/visible.data' | sed 's/.*: //')"
check 'excluded archive attribute precedence remains intact' archive "$(git -C "$LAB/vault" check-attr bridge-probe -- 'Course One/.sources/recording.zip.part001' | sed 's/.*: //')"
check 'complete initial index equals HEAD despite excluded files' yes "$(git -C "$LAB/vault" diff --cached --quiet HEAD && echo yes || echo no)"
check 'excluded archive stays in the complete index' yes "$(git -C "$LAB/vault" ls-files --error-unmatch 'Course One/.sources/recording.zip.part001' >/dev/null 2>&1 && echo yes || echo no)"
printf 'local visible\n' > "$LAB/vault/local.md"
await remote_has local.md || true
check 'add-A delivers visible local notes' yes "$(remote_has local.md && echo yes || echo no)"
check 'add-A cannot delete excluded archives from origin' 'recording archive' "$(git -C "$LAB/remote.git" show 'main:Course One/.sources/recording.zip.part001')"

git -C "$LAB/seed" pull -q --ff-only
mkdir -p "$LAB/seed/New Course/.sources" "$LAB/seed/New Course/.hidden/deep"
printf 'remote visible\n' > "$LAB/seed/remote.md"
printf 'new hidden archive\n' > "$LAB/seed/New Course/.sources/new.zip"
printf '*.bin bridge-probe=new\n' > "$LAB/seed/New Course/.hidden/deep/.gitattributes"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm remote-profile; git -C "$LAB/seed" push -q
await present remote.md || true
check 'fast-forward includes new visible content' yes "$(present remote.md && echo yes || echo no)"
check 'fast-forward omits future nested hidden archives' yes "$(absent 'New Course/.sources/new.zip' && echo yes || echo no)"
check 'fast-forward includes required files at newly introduced hidden depths' yes "$(present 'New Course/.hidden/deep/.gitattributes' && echo yes || echo no)"
stop
printf 'local diverged\n' > "$LAB/vault/diverged.md"
git -C "$LAB/vault" add -A; git -C "$LAB/vault" commit -qm local-diverged
printf 'remote diverged archive\n' > "$LAB/seed/Course One/.sources/diverged.zip"
git -C "$LAB/seed" add -A; git -C "$LAB/seed" commit -qm remote-diverged; git -C "$LAB/seed" push -q
start
await remote_has diverged.md || true
check 'divergent merge preserves remote hidden archive bytes' 'remote diverged archive' "$(git -C "$LAB/remote.git" show 'main:Course One/.sources/diverged.zip')"
check 'divergent merge preserves local visible bytes' 'local diverged' "$(git -C "$LAB/remote.git" show main:diverged.md)"
check 'divergent merge does not materialize hidden archive' yes "$(absent 'Course One/.sources/diverged.zip' && echo yes || echo no)"
stop

# Materialized files behind existing skip-worktree bits must not be silently
# removed when the same profile is reapplied on a later restart.
printf 'owner rematerialized bytes\n' > "$LAB/vault/Course One/.sources/recording.zip.part001"
before="$(git -C "$LAB/remote.git" rev-parse main)"
start; await refused || true
check 'existing sparse profile detects rematerialized tracked edits' yes "$(refused && echo yes || echo no)"
check 'rematerialized tracked edit remains byte-for-byte' 'owner rematerialized bytes' "$(cat "$LAB/vault/Course One/.sources/recording.zip.part001")"
check 'rematerialized edit refusal cannot advance origin' "$before" "$(git -C "$LAB/remote.git" rev-parse main)"
stop

clone_slot dirty
printf 'owner tracked edit\n' > "$LAB/dirty/Course One/.sources/recording.zip.part001"
printf 'owner untracked\n' > "$LAB/dirty/Course One/.sources/untracked.bin"
printf 'owner ignored\n' > "$LAB/dirty/Course One/.sources/ignored.tmp"
printf 'owner newline path\n' > "$LAB/dirty/Course One/.sources/line
break.bin"
before="$(git -C "$LAB/remote.git" rev-parse main)"
start; await refused || true
check 'dirty tracked excluded bytes are preserved' 'owner tracked edit' "$(cat "$LAB/dirty/Course One/.sources/recording.zip.part001")"
check 'untracked excluded bytes are preserved' 'owner untracked' "$(cat "$LAB/dirty/Course One/.sources/untracked.bin")"
check 'ignored excluded bytes are preserved' 'owner ignored' "$(cat "$LAB/dirty/Course One/.sources/ignored.tmp")"
check 'newline excluded path is preserved literally' 'owner newline path' "$(cat "$LAB/dirty/Course One/.sources/line
break.bin")"
check 'dirty refusal never advances origin' "$before" "$(git -C "$LAB/remote.git" rev-parse main)"
check 'dirty refusal is explicit' yes "$(refused && echo yes || echo no)"
stop

# Each excluded condition must independently refuse; a tracked edit cannot
# accidentally mask a broken ignored/untracked guard.
for condition in ignored untracked staged symlink; do
  clone_slot "only-$condition"
  case "$condition" in
    ignored) relative='Course One/.sources/only.tmp'; printf 'private ignored\n' > "$LAB/$SLOT/$relative";;
    untracked) relative='Course One/.sources/only.bin'; printf 'private untracked\n' > "$LAB/$SLOT/$relative";;
    staged) relative='Course One/.sources/recording.zip.part001'; printf 'private staged\n' > "$LAB/$SLOT/$relative"; git -C "$LAB/$SLOT" add -- "$relative";;
    symlink) relative='.private-link'; ln -s "$LAB/seed/note.md" "$LAB/$SLOT/$relative";;
  esac
  before="$(git -C "$LAB/remote.git" rev-parse main)"
  start; await refused || true
  check "$condition excluded bytes independently refuse profile changes" yes "$(refused && echo yes || echo no)"
  check "$condition refusal preserves the excluded path" yes "$([ -e "$LAB/$SLOT/$relative" ] && echo yes || echo no)"
  check "$condition refusal preserves origin" "$before" "$(git -C "$LAB/remote.git" rev-parse main)"
  stop
done

clone_slot migrate
printf '/*\n!/.agent-memory/\n' | git -C "$LAB/migrate" sparse-checkout set --no-cone --stdin
LEGACY=1; start; await present note.md || true; await absent 'Course One/.sources/recording.zip.part001' || true
check 'known legacy policy migrates to Obsidian profile' yes "$(absent 'Course One/.sources/recording.zip.part001' && echo yes || echo no)"
check 'migration retains full index with legacy flag still enabled' yes "$(git -C "$LAB/migrate" diff --cached --quiet HEAD && echo yes || echo no)"
stop; LEGACY=0

clone_slot custom
printf '/*\n!/unrelated-custom/\n' | git -C "$LAB/custom" sparse-checkout set --no-cone --stdin
policy_before="$(cat "$LAB/custom/.git/info/sparse-checkout")"
start; await refused || true
check 'custom sparse policy is refused unchanged' "$policy_before" "$(cat "$LAB/custom/.git/info/sparse-checkout")"
check 'custom-policy refusal keeps clean source bytes materialized' yes "$(present 'Course One/.sources/recording.zip.part001' && echo yes || echo no)"
stop

SLOT=invalid; PROFILE=typo; start
await grep -q 'VAULT_CHECKOUT_PROFILE must be full or obsidian' "$LAB/log-invalid" || true
check 'unknown checkout profile fails before cloning or writing notes' no "$([ -e "$LAB/invalid/.git" ] && echo yes || echo no)"
check 'unknown checkout profile reports its allowed values' yes "$(grep -q 'VAULT_CHECKOUT_PROFILE must be full or obsidian' "$LAB/log-invalid" && echo yes || echo no)"
stop

SLOT=full; PROFILE=full; start; await present note.md || true
check 'default full mode retains root Git-only files' yes "$(present .agent-memory/audit.md && echo yes || echo no)"
check 'default full mode retains nested Git-only archives' yes "$(present 'Course One/.sources/recording.zip.part001' && echo yes || echo no)"
stop

# A real LFS checkout must hydrate visible bytes without ever downloading the
# excluded recording cache. All transfers use a disposable local bare remote.
if command -v git-lfs >/dev/null 2>&1; then
  REPO="$LAB/lfs-remote.git"; SLOT=lfs; PROFILE=obsidian
  git init -q --bare "$REPO"; git init -q "$LAB/lfs-seed"
  git -C "$LAB/lfs-seed" config user.name fixture; git -C "$LAB/lfs-seed" config user.email fixture@example.invalid
  git -C "$LAB/lfs-seed" lfs install --local >/dev/null
  git -C "$LAB/lfs-seed" lfs track '*.bin' >/dev/null
  mkdir -p "$LAB/lfs-seed/Course/.sources"
  head -c 65536 /dev/zero > "$LAB/lfs-seed/visible.bin"
  head -c 1048576 /dev/zero > "$LAB/lfs-seed/Course/.sources/recording.bin"
  printf 'LFS source note\n' > "$LAB/lfs-seed/note.md"
  git -C "$LAB/lfs-seed" add -A; git -C "$LAB/lfs-seed" commit -qm lfs-seed; git -C "$LAB/lfs-seed" branch -M main
  git -C "$LAB/lfs-seed" remote add origin "$REPO"; git -C "$LAB/lfs-seed" push -qu origin main
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  archive_oid="$(git -C "$LAB/lfs-seed" show 'HEAD:Course/.sources/recording.bin' | sed -n 's/^oid sha256://p')"
  start; await present visible.bin || true
  check 'real LFS visible bytes are hydrated through retained attributes' 65536 "$(wc -c < "$LAB/lfs/visible.bin" | tr -d ' ')"
  check 'real LFS recording remains absent from worktree' yes "$(absent Course/.sources/recording.bin && echo yes || echo no)"
  check 'excluded LFS recording is never downloaded into derived cache' yes "$([ ! -f "$LAB/lfs/.git/lfs/objects/${archive_oid:0:2}/${archive_oid:2:2}/$archive_oid" ] && echo yes || echo no)"
  check 'real LFS sparse index retains the recording pointer' yes "$(git -C "$LAB/lfs" ls-files --error-unmatch Course/.sources/recording.bin >/dev/null 2>&1 && echo yes || echo no)"
  stop
else printf 'SKIP - real LFS fixture requires git-lfs (present in production Linux image)\n'; fi
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

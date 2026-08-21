#!/usr/bin/env bash
# The compression path is the ONLY place this daemon rewrites the bytes of a
# user's file, and it is also the one place where git holds no fallback copy:
# a file reaches that path by being OVER the size cap, which means it was
# refused and therefore never committed. So the write-back has exactly one
# acceptable behaviour - after any interruption, the file on disk is either the
# whole original or the whole re-encode, never a fragment of either.
#
# The implementation this suite guards replaced `cat "$tmp" > "$path"`, which
# truncates the destination at open() and then spends the whole copy with the
# user's only copy of that photo destroyed. Killed part-way through a 3 MB
# image, that left 4096 bytes and nothing else, anywhere.
#
# Unit-style, like test_conflict_modify_delete.sh: the real functions are
# extracted from bridge.sh and executed, so an inverted fix cannot pass. Two
# levels are covered deliberately - the swap primitive itself, AND
# compress_to_fit driving it, because a correct primitive nobody calls is the
# obvious way for this fix to regress.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$HERE/../bridge.sh"
PASS=0; FAIL=0; SKIP=0
# Isolate from the host's git config. NOT /dev/null: git >=2.43 parses a config
# path as a real file and errors "bad config line 1 in file /dev/null".
GIT_ISOLATED_CONFIG="$(mktemp)"
export GIT_CONFIG_GLOBAL="$GIT_ISOLATED_CONFIG" GIT_CONFIG_SYSTEM="$GIT_ISOLATED_CONFIG"

check() {
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1))
  else printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
skip() { printf 'skip - %s (environment: %s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$GIT_ISOLATED_CONFIG"' EXIT

extract_fn() { awk -v fn="$1" 'index($0, fn "()") == 1, /^}$/' "$BRIDGE"; }

{
  echo 'log() { printf "[test] %s\n" "$*"; }'
  echo 'MAX_FILE_MB="${VAULT_MAX_FILE_MB:-5}"'
  extract_fn compress_enabled
  extract_fn image_backend
  extract_fn image_reencode
  extract_fn image_verify
  extract_fn fsync_path
  extract_fn replace_file_atomically
  extract_fn compress_to_fit
} > "$TMP/swap.sh"

bash -n "$TMP/swap.sh" 2>/dev/null
check "the extracted swap code is valid shell" "0" "$?"
grep -q 'replace_file_atomically()' "$TMP/swap.sh"
check "replace_file_atomically extracted from the real bridge.sh" "0" "$?"
grep -q 'compress_to_fit()' "$TMP/swap.sh"
check "compress_to_fit extracted from the real bridge.sh" "0" "$?"

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
size_of() { stat -c%s "$1" 2>/dev/null || wc -c < "$1"; }

# ---------------------------------------------------------------------------
# 1. The deterministic proof: the original's bytes are never overwritten IN
#    PLACE. A hardlink made before the swap is a witness to the original inode -
#    if the implementation writes through the destination path into that same
#    inode (which is exactly what `cat > "$dst"` does), the witness is destroyed
#    along with the original and this fails. Nothing here depends on timing, so
#    it is the assertion that holds on any machine at any speed.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/one"
printf 'ORIGINAL-CONTENT-%s\n' "$(seq 1 2000 | tr -d '\n')" > "$TMP/one/dst.jpg"
printf 'REPLACEMENT-CONTENT\n' > "$TMP/one/src.jpg"
ORIG_SHA="$(sha_of "$TMP/one/dst.jpg")"
NEW_SHA="$(sha_of "$TMP/one/src.jpg")"
ln "$TMP/one/dst.jpg" "$TMP/one/witness.jpg"
check "witness really is a hardlink to the original (same content to start)" \
  "$ORIG_SHA" "$(sha_of "$TMP/one/witness.jpg")"

( set +u; . "$TMP/swap.sh"; replace_file_atomically "$TMP/one/src.jpg" "$TMP/one/dst.jpg" )
check "the swap reports success" "0" "$?"
check "the destination now holds the replacement, whole" "$NEW_SHA" "$(sha_of "$TMP/one/dst.jpg")"
check "the original inode was never written through - witness still intact" \
  "$ORIG_SHA" "$(sha_of "$TMP/one/witness.jpg")"
check "the source is consumed, not left beside the destination" "1" \
  "$([ -e "$TMP/one/src.jpg" ]; echo $?)"

# ---------------------------------------------------------------------------
# 2. Mode and ownership survive. The `cat` this replaced kept them for free by
#    never replacing the inode; a rename does not, so the implementation has to
#    carry them across by hand. A vault file that was 0640 must not silently
#    become 0644 (or, worse for a shared volume, world-readable).
# ---------------------------------------------------------------------------
mkdir -p "$TMP/two"
printf 'original\n' > "$TMP/two/dst.jpg"
printf 'replacement\n' > "$TMP/two/src.jpg"
chmod 0640 "$TMP/two/dst.jpg"
chmod 0600 "$TMP/two/src.jpg"      # deliberately DIFFERENT, so inheriting the
                                   # source's mode would be visible as a failure
( set +u; . "$TMP/swap.sh"; replace_file_atomically "$TMP/two/src.jpg" "$TMP/two/dst.jpg" )
check "the swap over a 0640 file succeeds" "0" "$?"
check "the destination's mode is preserved, not the source's" "640" \
  "$(stat -c%a "$TMP/two/dst.jpg" 2>/dev/null)"
check "the destination's content is the replacement" "replacement" \
  "$(cat "$TMP/two/dst.jpg" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 3. A cross-filesystem source is REFUSED, not silently degraded. `mv` across
#    devices is copy-then-unlink, which reopens the very truncation window this
#    function exists to close - so the correct answer is to fail and leave the
#    original alone, which makes the caller fall back to its ordinary refusal.
# ---------------------------------------------------------------------------
OTHER_FS=""
for cand in /dev/shm /run/shm; do
  [ -d "$cand" ] && [ -w "$cand" ] || continue
  [ "$(stat -c%d "$cand" 2>/dev/null)" != "$(stat -c%d "$TMP" 2>/dev/null)" ] || continue
  OTHER_FS="$cand"; break
done
if [ -n "$OTHER_FS" ]; then
  mkdir -p "$TMP/three"
  printf 'original\n' > "$TMP/three/dst.jpg"
  XSRC="$(mktemp "$OTHER_FS/vault-bridge-xdev.XXXXXX")"
  printf 'replacement\n' > "$XSRC"
  ( set +u; . "$TMP/swap.sh"; replace_file_atomically "$XSRC" "$TMP/three/dst.jpg" )
  check "a cross-device source is refused" "1" "$?"
  check "and the original is left completely untouched" "original" \
    "$(cat "$TMP/three/dst.jpg" 2>/dev/null)"
  rm -f "$XSRC"
else
  skip "cross-device source is refused" "no writable second filesystem to place the source on"
  skip "cross-device refusal leaves the original untouched" "no writable second filesystem to place the source on"
fi

# ---------------------------------------------------------------------------
# 4. THE REPRODUCTION: kill the swap part-way, over and over, and require that
#    what is on disk afterwards is always a WHOLE file - the original or the
#    replacement, never a fragment.
#
#    Two details make this a real reproduction rather than a formality:
#      - the payload is large enough that the operation takes real time (the
#        fsync alone does), so the kill delays genuinely land inside it;
#      - the process is killed by PROCESS GROUP. `kill -9 <shell-pid>` leaves
#        the external `mv`/`cat` child running to completion, which would let a
#        broken implementation finish its copy and pass. setsid gives the trial
#        its own group; killing the group stops the copy where it stands.
#
#    The straddle assertion at the end is the anti-vacuity guard: if every trial
#    landed on the same side, the kills never crossed the operation and the loop
#    proved nothing, so that is a failure rather than a quiet pass.
# ---------------------------------------------------------------------------
if ! command -v setsid >/dev/null 2>&1; then
  skip "an interrupted swap always leaves a whole file" "setsid (util-linux) is not installed, so the copy child cannot be killed with its shell"
  skip "the kill delays straddled the swap" "setsid (util-linux) is not installed, so the copy child cannot be killed with its shell"
else
  mkdir -p "$TMP/four"
  # 64 MB of incompressible bytes: big enough that a byte-copy implementation
  # spends a visible window with the destination truncated.
  head -c 67108864 /dev/urandom > "$TMP/four/payload-orig" 2>/dev/null
  head -c 67108864 /dev/urandom > "$TMP/four/payload-new" 2>/dev/null
  K_ORIG_SHA="$(sha_of "$TMP/four/payload-orig")"
  K_NEW_SHA="$(sha_of "$TMP/four/payload-new")"
  check "the two kill-test payloads really differ" "1" \
    "$([ "$K_ORIG_SHA" = "$K_NEW_SHA" ]; echo $?)"

  cat > "$TMP/four/trial.sh" <<TRIALEOF
set +u
. "$TMP/swap.sh"
replace_file_atomically "\$1" "\$2"
TRIALEOF

  saw_orig=0; saw_new=0; saw_partial=0; trials=0
  for delay in 0.001 0.003 0.005 0.008 0.012 0.018 0.025 0.035 0.050 0.070 0.095 0.130 0.170 0.220 0.280 0.350; do
    cp "$TMP/four/payload-orig" "$TMP/four/dst.jpg"
    cp "$TMP/four/payload-new"  "$TMP/four/src.jpg"
    setsid bash "$TMP/four/trial.sh" "$TMP/four/src.jpg" "$TMP/four/dst.jpg" >/dev/null 2>&1 &
    tpid=$!
    sleep "$delay"
    kill -9 -"$tpid" 2>/dev/null || kill -9 "$tpid" 2>/dev/null
    wait "$tpid" 2>/dev/null
    trials=$((trials+1))
    got="$(sha_of "$TMP/four/dst.jpg")"
    if   [ "$got" = "$K_ORIG_SHA" ]; then saw_orig=$((saw_orig+1))
    elif [ "$got" = "$K_NEW_SHA"  ]; then saw_new=$((saw_new+1))
    else
      saw_partial=$((saw_partial+1))
      printf '     trial killed after %ss left neither whole file: %s bytes\n' \
        "$delay" "$(size_of "$TMP/four/dst.jpg")"
    fi
    rm -f "$TMP/four/src.jpg"
  done

  check "every interrupted swap left a whole file (no fragments)" "0" "$saw_partial"
  check "all kill trials ran" "16" "$trials"
  # Straddle: some kills landed before the file changed hands and some after.
  # Without both, the delays never crossed the operation and the loop above is
  # not testing an interruption at all.
  check "some kills landed before the swap completed" "0" \
    "$([ "$saw_orig" -gt 0 ]; echo $?)"
  check "some kills landed after the swap completed" "0" \
    "$([ "$saw_new" -gt 0 ]; echo $?)"
  rm -f "$TMP/four/payload-orig" "$TMP/four/payload-new" "$TMP/four/dst.jpg"
fi

# ---------------------------------------------------------------------------
# 5. The CALL SITE. Everything above would still pass if compress_to_fit had
#    been left calling `cat`, so the real function is driven end to end here.
#
#    The image tool is stubbed rather than required: image_reencode/image_verify
#    /image_backend are thin wrappers over an external binary, and replacing
#    them lets the genuine compress_to_fit - its allowlist, its rungs, its size
#    gates, its write-back and its `git add` - run on every machine, including
#    ones with neither libvips nor Pillow. The logic under test is bridge.sh's
#    own; only the encoder is a double.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/five"
VDIR="$TMP/five/vault"
rm -rf "$VDIR"; mkdir -p "$VDIR"
git -C "$VDIR" init -q .
git -C "$VDIR" config user.email t@t.invalid
git -C "$VDIR" config user.name t
echo seed > "$VDIR/seed.md"
git -C "$VDIR" add -A && git -C "$VDIR" commit -qm base

head -c 6291456 /dev/urandom > "$VDIR/photo.jpg"     # 6 MB, over the 5 MB cap
chmod 0640 "$VDIR/photo.jpg"
git -C "$VDIR" add -A
PHOTO_ORIG_SHA="$(sha_of "$VDIR/photo.jpg")"
ln "$VDIR/photo.jpg" "$TMP/five/witness.jpg"

cat > "$TMP/five/driver.sh" <<'DRIVEREOF'
set +u
. "$SWAP"
# Encoder doubles. The real ones shell out to vips/Pillow; everything else in
# compress_to_fit is the genuine article.
compress_enabled() { return 0; }
image_backend()    { printf 'stub'; }
image_reencode()   { head -c 1048576 /dev/urandom > "$3"; }   # 1 MB, under cap
image_verify()     { [ -s "$2" ]; }   # (backend, path) - path is $2
compress_to_fit "photo.jpg" "$VAULT_DIR/photo.jpg" 6291456 5242880
DRIVEREOF

( set +u; export VAULT_DIR="$VDIR" SWAP="$TMP/swap.sh"; bash "$TMP/five/driver.sh" ) >/dev/null 2>&1
check "compress_to_fit accepts the re-encode" "0" "$?"
check "the working-tree file is now under the cap" "1048576" "$(size_of "$VDIR/photo.jpg")"
check "compress_to_fit went through the atomic swap - the original inode is intact" \
  "$PHOTO_ORIG_SHA" "$(sha_of "$TMP/five/witness.jpg")"
check "the destination's mode survived the call site's swap" "640" \
  "$(stat -c%a "$VDIR/photo.jpg" 2>/dev/null)"
# `git add -A` above already staged photo.jpg, so its mere presence in the
# index proves nothing. The staged BLOB SIZE does: it is the small re-encode
# only if compress_to_fit re-staged the file after the swap.
check "the SMALL file is what is staged, i.e. it was re-added after the swap" "1048576" \
  "$(git -C "$VDIR" cat-file -s :photo.jpg 2>/dev/null)"
# Scratch must not be left in the vault TREE, where the next `git add -A` would
# commit it, and must not survive under .git either.
check "no scratch file was left anywhere in the vault working tree" "" \
  "$(git -C "$VDIR" status --porcelain --untracked-files=all 2>/dev/null | grep -v '^A  photo.jpg$')"
check "no scratch directory was left under .git" "0" \
  "$(find "$VDIR/.git" -maxdepth 1 -name 'vault-bridge-compress.*' 2>/dev/null | wc -l)"

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]

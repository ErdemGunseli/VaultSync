#!/usr/bin/env bash
# Behavioural tests for VAULT_COMPRESS_IMAGES - the one place this daemon
# rewrites the contents of a user's file.
#
# The feature only ever reaches a file the size cap was going to REFUSE anyway,
# so the whole risk surface is "does it stay inside that boundary". These tests
# pin the boundary from both sides: that an opted-in oversize image really is
# re-encoded and committed, and that everything else - the flag off, a
# non-image, anything under the cap, an LFS pointer, a missing image tool, an
# image that will not shrink enough - is left exactly as untouched and as
# refused as it was before the feature existed.
#
# Unit-style, like test_conflict_modify_delete.sh: the real functions are
# extracted from bridge.sh and executed against a real git index, so an inverted
# fix cannot pass. One end-to-end case at the bottom runs the actual daemon.
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

await() {
  local secs="$1"; shift
  local i=0
  while [ "$i" -lt "$((secs * 2))" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

TMP="$(mktemp -d)"
BRIDGE_PID=""
trap '[ -n "$BRIDGE_PID" ] && kill $BRIDGE_PID 2>/dev/null; rm -rf "$TMP" "$GIT_ISOLATED_CONFIG"' EXIT

extract_fn() { awk -v fn="$1" 'index($0, fn "()") == 1, /^}$/' "$BRIDGE"; }

{
  echo 'log() { printf "[test] %s\n" "$*"; }'
  echo 'MAX_FILE_MB="${VAULT_MAX_FILE_MB:-5}"'
  extract_fn compress_enabled
  extract_fn image_backend
  extract_fn image_reencode
  extract_fn image_verify
  extract_fn compress_to_fit
  extract_fn enforce_size_cap
} > "$TMP/cap.sh"

bash -n "$TMP/cap.sh" 2>/dev/null
check "the extracted cap+compression code is valid shell" "0" "$?"
grep -q 'compress_to_fit()' "$TMP/cap.sh"
check "compression path extracted from the real bridge.sh" "0" "$?"

size_of() { stat -c%s "$1" 2>/dev/null || wc -c < "$1"; }
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# An image tool is a genuine ENVIRONMENT precondition for the cases that need a
# real re-encode: the container ships libvips (see Dockerfile) and most dev
# images carry python3+Pillow, but neither is guaranteed here. The cases that do
# NOT need one - the flag off, a non-image, under the cap, no tool at all - run
# unconditionally, so a toolless environment still exercises every refusal.
IMAGE_TOOL=""
if command -v vips >/dev/null 2>&1; then IMAGE_TOOL=vips
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' >/dev/null 2>&1; then IMAGE_TOOL=pillow; fi
skip() { printf 'skip - %s (environment: no vips and no python3+Pillow available)\n' "$1"; SKIP=$((SKIP+1)); }

# High-entropy image, so nothing here passes because a test fixture happened to
# be trivially compressible.
gen_image() {
  local out="$1" w="$2" h="$3"
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL' >/dev/null 2>&1; then
    python3 - "$out" "$w" "$h" <<'PYEOF'
import os
import sys

from PIL import Image

out, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
im = Image.frombytes("RGB", (w, h), os.urandom(w * h * 3))
if out.lower().endswith((".jpg", ".jpeg")):
    im.save(out, quality=97)
else:
    im.save(out)
PYEOF
  elif command -v vips >/dev/null 2>&1; then
    vips gaussnoise "${out}[Q=97]" "$w" "$h" --sigma 90 >/dev/null 2>&1
  else
    return 1
  fi
}

# A staged-but-not-yet-committed repo, the exact state enforce_size_cap runs in.
stage_repo() {
  local dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$dir" init -q .
  git -C "$dir" config user.email t@t.invalid
  git -C "$dir" config user.name t
  echo seed > "$dir/seed.md"
  git -C "$dir" add -A && git -C "$dir" commit -qm base
}

# Run the REAL enforce_size_cap over the staged index.
run_cap() {  # <dir> <logfile> [env assignments...]
  local dir="$1" logf="$2"; shift 2
  ( set +u; export VAULT_DIR="$dir"; [ $# -gt 0 ] && export "$@"
    . "$TMP/cap.sh"; enforce_size_cap ) >"$logf" 2>&1
}

# --- 1. Default OFF: behaviour is byte-for-byte what it was ------------------
# The image here is deliberately junk bytes: with the flag off nothing should
# ever try to decode it, and if something did, it would fail loudly.
stage_repo "$TMP/off"
head -c 6291456 /dev/urandom > "$TMP/off/photo.jpg"
git -C "$TMP/off" add -A
before="$(sha_of "$TMP/off/photo.jpg")"
check "case 1: the file really is staged and over the 5 MB cap" "yes" \
  "$(git -C "$TMP/off" diff --cached --name-only | grep -q photo.jpg && [ "$(size_of "$TMP/off/photo.jpg")" -gt 5242880 ] && echo yes || echo no)"
run_cap "$TMP/off" "$TMP/off.log"
check "case 1: with VAULT_COMPRESS_IMAGES unset, the file is unstaged as before" "0" \
  "$(git -C "$TMP/off" diff --cached --name-only | grep -c photo.jpg)"
check "case 1: the unchanged cap WARNING still names it" "yes" \
  "$(grep -q 'WARNING: photo.jpg exceeds sync cap' "$TMP/off.log" && echo yes || echo no)"
check "case 1: the file on disk was not touched" "$before" "$(sha_of "$TMP/off/photo.jpg")"
check "case 1: no compression was even attempted" "0" "$(grep -c 'COMPRESS' "$TMP/off.log")"

# 1b, with a genuinely decodable image: the log assertion above would still hold
# if the gate were removed and the encoder merely choked on junk bytes. This one
# would actually be rewritten, so it pins the gate on the file's contents rather
# than on a message.
if [ -z "$IMAGE_TOOL" ]; then
  skip "case 1b: a real image is untouched while the flag is off"
else
  stage_repo "$TMP/off2"
  gen_image "$TMP/off2/photo.jpg" 4000 3000
  git -C "$TMP/off2" add -A
  before="$(sha_of "$TMP/off2/photo.jpg")"
  check "case 1b: the fixture is a real image over the cap" "yes" \
    "$([ "$(size_of "$TMP/off2/photo.jpg")" -gt 5242880 ] && echo yes || echo no)"
  run_cap "$TMP/off2" "$TMP/off2.log"
  check "case 1b: a compressible image is left byte-identical while the flag is off" \
    "$before" "$(sha_of "$TMP/off2/photo.jpg")"
  check "case 1b: and refused exactly as before the feature existed" "0" \
    "$(git -C "$TMP/off2" diff --cached --name-only | grep -c photo.jpg)"
fi

# --- 2. Flag on, but the file is UNDER the cap: never touched ---------------
stage_repo "$TMP/under"
head -c 1048576 /dev/urandom > "$TMP/under/small.jpg"
git -C "$TMP/under" add -A
before="$(sha_of "$TMP/under/small.jpg")"
run_cap "$TMP/under" "$TMP/under.log" VAULT_COMPRESS_IMAGES=1
check "case 2: an under-cap image stays staged" "1" \
  "$(git -C "$TMP/under" diff --cached --name-only | grep -c small.jpg)"
check "case 2: and its bytes are untouched - compression never sees it" "$before" \
  "$(sha_of "$TMP/under/small.jpg")"
check "case 2: nothing was logged about it" "0" "$(grep -c 'COMPRESS' "$TMP/under.log")"

# --- 3. Flag on, oversize NON-allowlisted file: never even opened ------------
# The allowlist gates on the extension BEFORE any decode, so junk bytes are the
# right fixture: nothing should ever try to read them. '.gif' is here as well as
# '.zip' because it is an image format that is deliberately NOT allowlisted
# (re-encoding one would drop its animation) - adding it later should have to be
# a deliberate act that updates this test.
#
# Asserting "no COMPRESS line at all" rather than just "still refused" is
# load-bearing: with the allowlist deleted, the encoder fails on these bytes and
# the file ends up refused anyway, so a refusal-only assertion cannot tell the
# allowlist from its absence (measured - that mutant survived until this line
# was added).
for junk in archive.zip animation.gif; do
  stage_repo "$TMP/notimg"
  head -c 6291456 /dev/urandom > "$TMP/notimg/$junk"
  git -C "$TMP/notimg" add -A
  before="$(sha_of "$TMP/notimg/$junk")"
  run_cap "$TMP/notimg" "$TMP/notimg.log" VAULT_COMPRESS_IMAGES=1
  check "case 3 ($junk): an oversize non-allowlisted file is still refused" "0" \
    "$(git -C "$TMP/notimg" diff --cached --name-only | grep -c "$junk")"
  check "case 3 ($junk): with the unchanged WARNING" "yes" \
    "$(grep -q "WARNING: $junk exceeds sync cap" "$TMP/notimg.log" && echo yes || echo no)"
  check "case 3 ($junk): untouched bytes" "$before" "$(sha_of "$TMP/notimg/$junk")"
  check "case 3 ($junk): compression was never even attempted on it" "0" \
    "$(grep -c 'COMPRESS' "$TMP/notimg.log")"
done

# --- 4. Flag on, no image tool at all: refuse loudly, never silently ---------
# Real environment control, not a stub: PATH is emptied of anything that could
# decode an image, which is exactly the runtime state if libvips is ever missing
# from the container.
stage_repo "$TMP/notool"
head -c 6291456 /dev/urandom > "$TMP/notool/photo.png"
git -C "$TMP/notool" add -A
before="$(sha_of "$TMP/notool/photo.png")"
NO_TOOL_BIN="$TMP/nobin"; mkdir -p "$NO_TOOL_BIN"
for c in git stat wc mktemp cat rm grep tr printf find sha256sum awk sed head; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$NO_TOOL_BIN/$c"
done
( set +u; export VAULT_DIR="$TMP/notool" VAULT_COMPRESS_IMAGES=1 PATH="$NO_TOOL_BIN"
  . "$TMP/cap.sh"; enforce_size_cap ) >"$TMP/notool.log" 2>&1
# `command -v` is a bash builtin, so this probe still works inside a PATH that
# holds almost nothing. An earlier version shelled out to `sh`, which is not in
# the sandbox either - it "passed" because the probe itself failed to run.
check "case 4: the sandboxed PATH really has no image tool" "yes" \
  "$( (PATH="$NO_TOOL_BIN"; if command -v vips >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then echo no; else echo yes; fi) )"
check "case 4: the missing tool is reported against the path, not silently ignored" "yes" \
  "$(grep -q "COMPRESS: 'photo.png' is over the cap" "$TMP/notool.log" && echo yes || echo no)"
check "case 4: and the log names what to install" "yes" \
  "$(grep -q 'libvips-tools' "$TMP/notool.log" && echo yes || echo no)"
check "case 4: the file is refused exactly as if the feature were off" "0" \
  "$(git -C "$TMP/notool" diff --cached --name-only | grep -c photo.png)"
check "case 4: and the unchanged cap WARNING still fires" "yes" \
  "$(grep -q 'WARNING: photo.png exceeds sync cap' "$TMP/notool.log" && echo yes || echo no)"
check "case 4: bytes untouched" "$before" "$(sha_of "$TMP/notool/photo.png")"

# --- 5. Flag on, LFS-tracked oversize image: never re-encoded ----------------
# git-lfs commits a small pointer whatever the working tree holds, so
# re-encoding an LFS path destroys pixels for zero size gain. .gitattributes is
# written AFTER staging on purpose: it keeps the test from depending on the
# git-lfs binary being installed, while `git check-attr` - which is what the
# code consults - reads the worktree file either way.
stage_repo "$TMP/lfs"
head -c 6291456 /dev/urandom > "$TMP/lfs/photo.jpg"
git -C "$TMP/lfs" add -A
printf '*.jpg filter=lfs diff=lfs merge=lfs -text\n' > "$TMP/lfs/.gitattributes"
check "case 5: git really reports the path as lfs-filtered" "yes" \
  "$(git -C "$TMP/lfs" check-attr filter -- photo.jpg | grep -q 'filter: lfs' && echo yes || echo no)"
before="$(sha_of "$TMP/lfs/photo.jpg")"
run_cap "$TMP/lfs" "$TMP/lfs.log" VAULT_COMPRESS_IMAGES=1
check "case 5: an LFS-tracked image is not re-encoded" "$before" "$(sha_of "$TMP/lfs/photo.jpg")"
check "case 5: and the log says why it was skipped" "yes" \
  "$(grep -q 'git-lfs tracked' "$TMP/lfs.log" && echo yes || echo no)"
check "case 5: the pre-existing refusal is unchanged (still measured on disk)" "yes" \
  "$(grep -q 'WARNING: photo.jpg exceeds sync cap' "$TMP/lfs.log" && echo yes || echo no)"

# --- 6. The real thing: an oversize JPEG is compressed and committed ---------
if [ -z "$IMAGE_TOOL" ]; then
  skip "case 6: an oversize JPEG is re-encoded under the cap and committed"
else
  stage_repo "$TMP/jpg"
  gen_image "$TMP/jpg/photo.jpg" 4000 3000
  orig="$(size_of "$TMP/jpg/photo.jpg")"
  before="$(sha_of "$TMP/jpg/photo.jpg")"
  git -C "$TMP/jpg" add -A
  check "case 6: the fixture really is a decodable image over the cap" "yes" \
    "$([ "$orig" -gt 5242880 ] && echo yes || echo "no ($orig bytes)")"
  run_cap "$TMP/jpg" "$TMP/jpg.log" VAULT_COMPRESS_IMAGES=1
  after="$(size_of "$TMP/jpg/photo.jpg")"
  check "case 6: the image is now under the 5 MB cap" "yes" \
    "$([ "$after" -le 5242880 ] && echo yes || echo "no ($after bytes)")"
  check "case 6: it was actually rewritten" "yes" \
    "$([ "$(sha_of "$TMP/jpg/photo.jpg")" != "$before" ] && echo yes || echo no)"
  check "case 6: and it stays staged, so it will be committed" "1" \
    "$(git -C "$TMP/jpg" diff --cached --name-only | grep -c photo.jpg)"
  check "case 6: the STAGED blob is the compressed bytes, not the original" "$after" \
    "$(git -C "$TMP/jpg" show ":photo.jpg" 2>/dev/null | wc -c | tr -d ' ')"
  check "case 6: the cap's refusal did NOT fire" "0" "$(grep -c 'exceeds sync cap' "$TMP/jpg.log")"
  check "case 6: the re-encode is logged with the path" "yes" \
    "$(grep -q "COMPRESSED: 'photo.jpg'" "$TMP/jpg.log" && echo yes || echo no)"
  check "case 6: and with before/after sizes" "yes" \
    "$(grep -qE 'COMPRESSED:.*[0-9]+ MB -> [0-9]+ MB' "$TMP/jpg.log" && echo yes || echo no)"
  # Still a real JPEG, same format - a "compression" that produced a corrupt or
  # differently-typed file would satisfy every size assertion above.
  if [ "$IMAGE_TOOL" = pillow ] || python3 -c 'import PIL' >/dev/null 2>&1; then
    check "case 6: the result is still a valid JPEG" "JPEG" \
      "$(python3 -c 'from PIL import Image;print(Image.open("'"$TMP/jpg/photo.jpg"'").format)' 2>/dev/null)"
  else
    check "case 6: the result is still a valid JPEG" "0" \
      "$(vips jpegload "$TMP/jpg/photo.jpg" "$TMP/probe.v" >/dev/null 2>&1; echo $?)"
  fi
fi

# --- 7. Uppercase extension is matched too ----------------------------------
if [ -z "$IMAGE_TOOL" ]; then
  skip "case 7: an uppercase .JPG extension is on the allowlist"
else
  stage_repo "$TMP/upper"
  gen_image "$TMP/upper/PHOTO.JPG" 4000 3000
  git -C "$TMP/upper" add -A
  check "case 7: the .JPG fixture is over the cap" "yes" \
    "$([ "$(size_of "$TMP/upper/PHOTO.JPG")" -gt 5242880 ] && echo yes || echo no)"
  run_cap "$TMP/upper" "$TMP/upper.log" VAULT_COMPRESS_IMAGES=1
  check "case 7: extension matching is case-insensitive" "yes" \
    "$(grep -q "COMPRESSED: 'PHOTO.JPG'" "$TMP/upper.log" && echo yes || echo no)"
  check "case 7: and it is under the cap and staged" "1" \
    "$(git -C "$TMP/upper" diff --cached --name-only | grep -c PHOTO.JPG)"
fi

# --- 8. THE FLOOR: what cannot be shrunk enough is still refused -------------
# A 3000x3000 noise PNG cannot reach 1 MB even at the last rung (1280px,
# palette), on either backend. The point of the case is that the daemon does not
# "nearly" succeed and commit an oversized file anyway.
if [ -z "$IMAGE_TOOL" ]; then
  skip "case 8: an image that cannot fit is still refused"
else
  stage_repo "$TMP/floor"
  gen_image "$TMP/floor/huge.png" 3000 3000
  git -C "$TMP/floor" add -A
  before="$(sha_of "$TMP/floor/huge.png")"
  check "case 8: the fixture is over the 1 MB cap used here" "yes" \
    "$([ "$(size_of "$TMP/floor/huge.png")" -gt 1048576 ] && echo yes || echo no)"
  run_cap "$TMP/floor" "$TMP/floor.log" VAULT_COMPRESS_IMAGES=1 VAULT_MAX_FILE_MB=1
  check "case 8: compression was genuinely attempted and gave up" "yes" \
    "$(grep -q 'could not bring' "$TMP/floor.log" && echo yes || echo no)"
  check "case 8: the file is NOT committed - the hard refusal is the floor" "0" \
    "$(git -C "$TMP/floor" diff --cached --name-only | grep -c huge.png)"
  check "case 8: the unchanged cap WARNING still fires" "yes" \
    "$(grep -q 'WARNING: huge.png exceeds sync cap' "$TMP/floor.log" && echo yes || echo no)"
  check "case 8: and the original is left intact, not half-rewritten" "$before" \
    "$(sha_of "$TMP/floor/huge.png")"
fi

# --- 8b. The decode gate that stands between a half-written file and the
#         user's only copy of a photo --------------------------------------
# It is the last thing checked before the original is overwritten, so it has to
# actually work. Both of its incantations were wrong on the first attempt and
# would have failed silently in OPPOSITE directions: `vips header` is not a
# libvips action at all (it exits non-zero on every file, which would have
# disabled compression entirely), and plain `vips avg` succeeds on a JPEG
# truncated to half its bytes (which would have waved a corrupt file through).
# Hence a direct test rather than trust.
if [ -z "$IMAGE_TOOL" ]; then
  skip "case 8b: the re-encode is verified by decoding it"
else
  gen_image "$TMP/verify.jpg" 800 600
  ( set +u; . "$TMP/cap.sh"; image_verify "$IMAGE_TOOL" "$TMP/verify.jpg" ) >/dev/null 2>&1
  check "case 8b: a whole image verifies" "0" "$?"
  full="$(size_of "$TMP/verify.jpg")"
  check "case 8b: the fixture is big enough to truncate meaningfully" "yes" \
    "$([ "$full" -gt 2000 ] && echo yes || echo no)"
  head -c "$(( full / 2 ))" "$TMP/verify.jpg" > "$TMP/verify-trunc.jpg"
  ( set +u; . "$TMP/cap.sh"; image_verify "$IMAGE_TOOL" "$TMP/verify-trunc.jpg" ) >/dev/null 2>&1
  check "case 8b: a half-written image does NOT verify" "1" "$?"
  : > "$TMP/verify-empty.jpg"
  ( set +u; . "$TMP/cap.sh"; image_verify "$IMAGE_TOOL" "$TMP/verify-empty.jpg" ) >/dev/null 2>&1
  check "case 8b: an empty file does NOT verify" "1" "$?"
  ( set +u; . "$TMP/cap.sh"; image_verify "$IMAGE_TOOL" "$TMP/nonexistent.jpg" ) >/dev/null 2>&1
  check "case 8b: a missing file does NOT verify" "1" "$?"
fi

# --- 8d. …and it is actually wired in ---------------------------------------
# 8b proves image_verify works; this proves compress_to_fit consults it. The
# only way to reach the "encoder exited 0 but wrote a corrupt file" branch
# without a fake encoder on PATH is to make verification itself refuse, so this
# one case overrides image_verify - and nothing else. Every other function,
# including compress_to_fit, is the real code from bridge.sh, and the assertion
# is behavioural: the original survives and the file stays refused.
if [ -z "$IMAGE_TOOL" ]; then
  skip "case 8d: a re-encode that fails verification never overwrites the original"
else
  stage_repo "$TMP/badverify"
  gen_image "$TMP/badverify/photo.jpg" 4000 3000
  git -C "$TMP/badverify" add -A
  before="$(sha_of "$TMP/badverify/photo.jpg")"
  ( set +u; export VAULT_DIR="$TMP/badverify" VAULT_COMPRESS_IMAGES=1
    . "$TMP/cap.sh"
    image_verify() { return 1; }
    enforce_size_cap ) >"$TMP/badverify.log" 2>&1
  check "case 8d: an unverifiable re-encode is never written back" "$before" \
    "$(sha_of "$TMP/badverify/photo.jpg")"
  check "case 8d: and the file is refused, not committed" "0" \
    "$(git -C "$TMP/badverify" diff --cached --name-only | grep -c photo.jpg)"
  check "case 8d: with the unchanged cap WARNING" "yes" \
    "$(grep -q 'WARNING: photo.jpg exceeds sync cap' "$TMP/badverify.log" && echo yes || echo no)"
  # Control: the SAME fixture with real verification does get compressed, so the
  # case above cannot pass because of something unrelated to verification.
  stage_repo "$TMP/goodverify"
  cp "$TMP/badverify/photo.jpg" "$TMP/goodverify/photo.jpg"
  git -C "$TMP/goodverify" add -A
  run_cap "$TMP/goodverify" "$TMP/goodverify.log" VAULT_COMPRESS_IMAGES=1
  check "case 8d control: the same image DOES compress when verification passes" "1" \
    "$(git -C "$TMP/goodverify" diff --cached --name-only | grep -c photo.jpg)"
fi

# --- 8c. The allowlist matches extensions literally, not as globs ------------
# 'photo.j[p]g' is a legal filename, and '[p]' is a glob that matches 'p'. The
# allowlist test is a `case`, so if the extension is ever expanded UNQUOTED
# there it stops being a string and becomes a pattern - 'j[p]g' then matches
# 'jpg', the file is sent to an encoder that cannot write it, and the allowlist
# has quietly stopped being one. The current quoted form is safe (measured, not
# assumed: this case survives a rewrite between the two safe forms and fails
# only when the quotes go).
stage_repo "$TMP/glob"
head -c 6291456 /dev/urandom > "$TMP/glob/photo.j[p]g"
git -C "$TMP/glob" add -A
check "case 8c: the odd filename really is staged" "1" \
  "$(git -C "$TMP/glob" diff --cached --name-only | grep -cF 'photo.j[p]g')"
before="$(sha_of "$TMP/glob/photo.j[p]g")"
run_cap "$TMP/glob" "$TMP/glob.log" VAULT_COMPRESS_IMAGES=1
check "case 8c: a glob-shaped extension is not on the allowlist" "0" \
  "$(grep -c 'COMPRESS' "$TMP/glob.log")"
check "case 8c: and its bytes are untouched" "$before" "$(sha_of "$TMP/glob/photo.j[p]g")"

# --- 9. End-to-end: the compressed image actually reaches the remote --------
if [ -z "$IMAGE_TOOL" ]; then
  skip "case 9: end-to-end, a compressed image reaches the remote under the cap"
else
  git init -q --bare "$TMP/remote.git"
  git init -q "$TMP/seed" && (
    cd "$TMP/seed"
    git config user.email t@t.invalid && git config user.name t
    echo hello > note.md && git add -A && git commit -qm init
    git branch -M main && git remote add origin "$TMP/remote.git" && git push -q origin main
  )
  git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/main

  env VAULT_NAME=compress \
      VAULT_REPO="$TMP/remote.git" \
      VAULT_DIR="$TMP/vault" \
      VAULT_BRANCH=main \
      VAULT_BRIDGE_INTERVAL=1 \
      VAULT_COMPRESS_IMAGES=1 \
      XDG_CONFIG_HOME="$TMP/obstate" \
      bash "$BRIDGE" > "$TMP/e2e.log" 2>&1 &
  BRIDGE_PID=$!

  await 20 test -f "$TMP/vault/note.md"
  check "case 9: bridge clones before the image is written" "0" "$?"

  mkdir -p "$TMP/vault/Attachments"
  gen_image "$TMP/e2e-src.jpg" 4000 3000
  cp "$TMP/e2e-src.jpg" "$TMP/vault/Attachments/photo.jpg"
  check "case 9: the written image starts over the cap" "yes" \
    "$([ "$(size_of "$TMP/vault/Attachments/photo.jpg")" -gt 5242880 ] && echo yes || echo no)"

  landed() { git -C "$TMP/remote.git" show "main:Attachments/photo.jpg" >/dev/null 2>&1; }
  await 30 landed
  check "case 9: the image reaches the remote instead of being refused" "0" "$?"
  remote_size="$(git -C "$TMP/remote.git" show "main:Attachments/photo.jpg" 2>/dev/null | wc -c | tr -d ' ')"
  check "case 9: and what landed is under the cap" "yes" \
    "$([ "$remote_size" -le 5242880 ] && echo yes || echo "no ($remote_size bytes)")"
  check "case 9: the daemon logged the re-encode" "yes" \
    "$(grep -q 'COMPRESSED:' "$TMP/e2e.log" && echo yes || echo no)"

  kill "$BRIDGE_PID" 2>/dev/null; wait "$BRIDGE_PID" 2>/dev/null; BRIDGE_PID=""
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]

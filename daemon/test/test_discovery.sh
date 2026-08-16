#!/usr/bin/env bash
# Behavioural tests for entrypoint.sh vault discovery.
#
# These RUN the entrypoint against temporary directories with a stub bridge and
# assert on what it actually launched (vault names, per-vault env, vault dirs).
# Nothing here greps entrypoint.sh's source, so a rename cannot fake a pass and
# inverted logic cannot slip through.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$HERE/../entrypoint.sh"
PASS=0; FAIL=0

# A stub standing in for bridge.sh: record what env it was handed, then exit.
make_stub() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "LAUNCHED name=${VAULT_NAME:-} repo=${VAULT_REPO:-} dir=${VAULT_DIR:-} token=${OBSIDIAN_AUTH_TOKEN:-} encpw=${VAULT_SYNC_ENCRYPTION_PASSWORD:-}"
exit 0
STUB
  chmod +x "$1"
}

# run <secrets-dir> <extra-env...> -> captured output
run_entry() {
  local secrets="$1"; shift
  local tmp; tmp="$(mktemp -d)"
  make_stub "$tmp/bridge.sh"
  env -i PATH="$PATH" HOME="$tmp" \
      SECRETS_DIR="$secrets" DATA_DIR="$tmp/data" \
      XDG_CONFIG_HOME="$tmp/data/ob-state" BRIDGE_BIN="$tmp/bridge.sh" \
      "$@" timeout 4 bash "$ENTRY" 2>&1
  rm -rf "$tmp"
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   - %s\n' "$label"; PASS=$((PASS+1))
  else
    printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"; FAIL=$((FAIL+1))
  fi
}

# --- 1. Multi-vault: one secret file per vault, discovered by filename -------
S="$(mktemp -d)"
printf 'VAULT_REPO=https://example.invalid/a.git\n' > "$S/vault-alpha.env"
printf 'VAULT_REPO=https://example.invalid/b.git\n' > "$S/vault-beta.env"
printf 'VAULT_REPO=https://example.invalid/x.git\n' > "$S/not-a-vault.env"   # must be ignored
OUT="$(run_entry "$S")"
names="$(echo "$OUT" | grep -o 'LAUNCHED name=[a-z]*' | sed 's/LAUNCHED name=//' | sort | tr '\n' ',')"
check "discovers one vault per vault-*.env, ignores other files" "alpha,beta," "$names"

repo_a="$(echo "$OUT" | grep 'name=alpha' | grep -o 'repo=[^ ]*' | sed 's/repo=//')"
check "each vault gets ITS OWN secret file's env" "https://example.invalid/a.git" "$repo_a"

dir_b="$(echo "$OUT" | grep 'name=beta' | grep -o 'dir=[^ ]*' | sed 's|.*/data/|/data/|')"
check "vault dir derives from the vault name" "/data/vaults/beta" "$dir_b"
rm -rf "$S"

# --- 2. Single-vault plain-env mode (no secret files at all) ----------------
S="$(mktemp -d)"
OUT="$(run_entry "$S" VAULT_REPO=https://example.invalid/solo.git VAULT_NAME=solo)"
names="$(echo "$OUT" | grep -c 'LAUNCHED name=solo')"
check "plain-env mode launches exactly one vault" "1" "$names"
rm -rf "$S"

# --- 3. Plain-env mode defaults the name when only VAULT_REPO is set --------
S="$(mktemp -d)"
OUT="$(run_entry "$S" VAULT_REPO=https://example.invalid/solo.git)"
check "defaults VAULT_NAME to planning" "1" "$(echo "$OUT" | grep -c 'LAUNCHED name=planning')"
rm -rf "$S"

# --- 4. No config at all: idle, do NOT launch and do NOT crash --------------
S="$(mktemp -d)"
OUT="$(run_entry "$S")"
check "no config launches nothing" "0" "$(echo "$OUT" | grep -c 'LAUNCHED')"
check "no config idles with an explanation" "1" "$(echo "$OUT" | grep -c 'nothing to do')"
rm -rf "$S"

# --- 5. A secret file's own VAULT_NAME must not override the filename -------
# The filename is the identity; otherwise two files could claim one vault and
# silently share sync state.
S="$(mktemp -d)"
printf 'VAULT_REPO=https://example.invalid/c.git\nVAULT_NAME=impostor\n' > "$S/vault-real.env"
OUT="$(run_entry "$S")"
check "filename wins over VAULT_NAME inside the file" "1" "$(echo "$OUT" | grep -c 'LAUNCHED name=real')"
rm -rf "$S"

# --- 6. Container-level per-vault env must NOT bleed into secret-file vaults -
# A global VAULT_REPO/VAULT_DIR would otherwise point every vault at one repo
# and cross-contaminate their sync state.
S="$(mktemp -d)"
printf 'VAULT_REPO=https://example.invalid/own.git\n' > "$S/vault-one.env"
printf 'VAULT_REPO=https://example.invalid/two.git\n' > "$S/vault-two.env"
OUT="$(run_entry "$S" VAULT_REPO=https://example.invalid/GLOBAL.git VAULT_DIR=/data/GLOBAL)"
check "global VAULT_REPO does not override a vault's own" "0" "$(echo "$OUT" | grep -c 'GLOBAL.git')"
check "global VAULT_DIR does not collapse vaults into one dir" "0" "$(echo "$OUT" | grep -c 'dir=/data/GLOBAL')"
check "both vaults still use their own repo" "2" "$(echo "$OUT" | grep -c 'repo=https://example.invalid/\(own\|two\).git')"
rm -rf "$S"

# --- 7. Env-group mode: VAULTS list + namespaced vars, fully env-driven ------
S="$(mktemp -d)"
OUT="$(run_entry "$S" VAULTS="alpha,beta" \
  VAULT_ALPHA_REPO=https://example.invalid/a.git \
  VAULT_BETA_REPO=https://example.invalid/b.git \
  VAULT_BETA_SYNC_ENCRYPTION_PASSWORD=beta-only-secret)"
names="$(echo "$OUT" | grep -o 'LAUNCHED name=[a-z]*' | sed 's/LAUNCHED name=//' | sort | tr '\n' ',')"
check "VAULTS list launches one bridge per name" "alpha,beta," "$names"
repo_a="$(echo "$OUT" | grep 'name=alpha' | grep -o 'repo=[^ ]*' | sed 's/repo=//')"
check "namespaced VAULT_<NAME>_REPO maps to the right vault" "https://example.invalid/a.git" "$repo_a"
check "a per-vault encryption password does not bleed to a sibling" "0" \
  "$(echo "$OUT" | grep 'name=alpha' | grep -c 'beta-only-secret')"
check "the owning vault does receive its password" "1" \
  "$(echo "$OUT" | grep 'name=beta' | grep -c 'encpw=beta-only-secret')"
rm -rf "$S"

# --- 8. VAULTS mode wins over secret files (one source of truth at a time) ---
S="$(mktemp -d)"
printf 'VAULT_REPO=https://example.invalid/file.git\n' > "$S/vault-filemode.env"
OUT="$(run_entry "$S" VAULTS="envmode" VAULT_ENVMODE_REPO=https://example.invalid/env.git)"
check "VAULTS mode takes precedence over secret files" "1" \
  "$(echo "$OUT" | grep -c 'LAUNCHED name=envmode')"
check "secret-file vault is not also launched" "0" \
  "$(echo "$OUT" | grep -c 'LAUNCHED name=filemode')"
rm -rf "$S"

# --- 9. Half-added vault: in VAULTS but no repo key -> loud boot warning -----
S="$(mktemp -d)"
OUT="$(run_entry "$S" VAULTS="alpha,ghost" VAULT_ALPHA_REPO=https://example.invalid/a.git)"
check "half-added vault warned about at boot" "1" \
  "$(echo "$OUT" | grep -c "vault 'ghost' is HALF-ADDED")"
check "the warning names the GIT_TOKEN obligation" "yes" \
  "$([ "$(echo "$OUT" | grep -c 'extend GIT_TOKEN')" -ge 1 ] && echo yes || echo no)"
check "the fully-added sibling still launches" "1" "$(echo "$OUT" | grep -c 'LAUNCHED name=alpha')"
rm -rf "$S"

# --- 10. Placeholder values fail closed, loudly (REAL bridge, no stub) -------
T="$(mktemp -d)"
POUT="$(env -i PATH="$PATH" HOME="$T" XDG_CONFIG_HOME="$T/ob" TMPDIR="$T" \
  VAULT_NAME=ph VAULT_DIR="$T/vault" \
  VAULT_REPO="https://github.com/x/y.git" GIT_TOKEN="REPLACE_ME" \
  timeout 10 bash "$HERE/../bridge.sh" 2>&1)"
rc=$?
check "REPLACE_ME placeholder is fatal, not a confusing auth error" "1" "$rc"
check "the fatal message says what to fix" "yes" \
  "$([ "$(echo "$POUT" | grep -c 'REPLACE_ME placeholder')" -ge 1 ] && echo yes || echo no)"
rm -rf "$T"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

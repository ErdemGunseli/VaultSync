#!/usr/bin/env bash
# Two transports move a bridged vault, and only one of them is selective.
#
# git <-> VAULT_DIR carries every tracked byte, .obsidian/ included. Obsidian
# Sync moves VAULT_DIR <-> devices and carries ONLY the config categories named
# in its stored per-vault config. `ob sync-setup` writes no such key, and the
# sync engine reads a missing key as an EMPTY set - config syncing fully off.
#
# The daemon used to pass `--configs` only when VAULT_SYNC_CONFIGS was set, and
# `ob sync-config` gates on `configs !== undefined`, so an omitted flag left the
# stored (empty) value untouched rather than applying any default. A vault whose
# .obsidian/ tree was complete in git and on disk therefore landed on every
# device with zero plugins, and nothing in any log said so. That is the failure
# these tests pin closed.
#
# Style follows test_conflict_dotfolder.sh: the REAL functions and the REAL
# top-level assignments are extracted from bridge.sh and executed. Only `ob_q`
# and `log` are stubbed, because they are the process boundary - stubbing
# anything else would test the stub.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$HERE/../bridge.sh"
PASS=0; FAIL=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; PASS=$((PASS+1))
  else printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pull a function out of bridge.sh verbatim - same helper the other suites use.
extract_fn() { awk -v fn="$1" 'index($0, fn "()") == 1, /^}$/' "$BRIDGE"; }
# Pull a single top-level line out of bridge.sh verbatim, by its exact prefix.
# The default-resolution logic is two assignments at file scope, not a function,
# so this is how the REAL default reaches the harness rather than a copy of it
# that could drift from bridge.sh without any test noticing.
extract_line() { grep -m1 "^$1" "$BRIDGE"; }

# The harness `apply_sync_config` runs inside. ARGV_FILE records the exact argv
# handed to `ob_q`, one argument per line, so an EMPTY argument is still a
# visible line - which is the whole point for the `--configs ""` case.
harness() {
  cat <<HARNESS
set -u
ARGV_FILE="$TMP/argv"
LOG_FILE="$TMP/log"
: > "\$ARGV_FILE"; : > "\$LOG_FILE"
VAULT_DIR="/data/vaults/testvault"
log() { printf '%s\n' "\$*" >> "\$LOG_FILE"; }
ob_q() { printf '%s\n' "\$@" >> "\$ARGV_FILE"; return \${OB_Q_RC:-0}; }
HARNESS
  extract_line 'SYNC_CONFIGS_DEFAULT='
  extract_line 'SYNC_CONFIGS='
  extract_line 'SYNC_FILE_TYPES_DEFAULT='
  extract_line 'SYNC_FILE_TYPES='
  extract_line 'SYNC_CONFIGS_STATE='
  extract_fn apply_sync_config
}

# Run apply_sync_config under a given VAULT_SYNC_CONFIGS state and echo the
# resulting SYNC_CONFIGS_STATE. `mode` is unset|set|empty, deliberately three
# cases: `${VAR-default}` vs `${VAR:-default}` differ ONLY on the third, and
# that difference is a real operator-visible behaviour.
run_apply() {
  local mode="$1" value="${2:-}" rc="${3:-0}"
  {
    harness
    case "$mode" in
      unset) echo 'unset VAULT_SYNC_CONFIGS 2>/dev/null || true' ;;
    esac
    echo "OB_Q_RC=$rc"
    echo 'apply_sync_config >/dev/null 2>&1'
    echo 'printf "%s" "$SYNC_CONFIGS_STATE"'
  } > "$TMP/script.sh"
  case "$mode" in
    set)   VAULT_SYNC_CONFIGS="$value" bash "$TMP/script.sh" ;;
    empty) VAULT_SYNC_CONFIGS=""       bash "$TMP/script.sh" ;;
    *)     env -u VAULT_SYNC_CONFIGS   bash "$TMP/script.sh" ;;
  esac
}

# The value of the --configs argument as ob_q actually received it. Prints the
# line AFTER "--configs"; prints the marker <MISSING> when the flag is absent
# and <EMPTY> when it was passed as an empty string, so the three outcomes that
# matter are never conflated into one another.
configs_arg() {
  awk '
    found { if ($0 == "") { print "<EMPTY>" } else { print }; exit }
    $0 == "--configs" { found = 1 }
    END { if (!found) print "<MISSING>" }
  ' "$TMP/argv"
}
filetypes_arg() {
  awk '
    found { if ($0 == "") { print "<EMPTY>" } else { print }; exit }
    $0 == "--file-types" { found = 1 }
    END { if (!found) print "<MISSING>" }
  ' "$TMP/argv"
}

ALL8="app,appearance,appearance-data,hotkey,core-plugin,core-plugin-data,community-plugin,community-plugin-data"

echo "--- the default carries every config category ---"

state="$(run_apply unset)"
check "with VAULT_SYNC_CONFIGS unset, --configs is passed at all" \
  "yes" "$([ "$(configs_arg)" = "<MISSING>" ] && echo no || echo yes)"
check "with VAULT_SYNC_CONFIGS unset, --configs carries all eight categories" \
  "$ALL8" "$(configs_arg)"
check "a successful sync-config records state ok" "ok" "$state"
check "the category list is logged, so the choice is answerable from logs" \
  "1" "$(grep -c "sync-config: asking Obsidian Sync to carry config categories: $ALL8" "$TMP/log")"

# The conflict-strategy reasoning predates this change and must survive it: the
# bridge deliberately matches Sync's own auto-merge behaviour rather than
# littering a bridged vault with conflicted copies a Sync-only user never sees.
check "the default invocation still pins --conflict-strategy merge" \
  "merge" "$(awk '/^--conflict-strategy$/ { getline; print; exit }' "$TMP/argv")"
check "the default invocation still pins --mode bidirectional" \
  "bidirectional" "$(awk '/^--mode$/ { getline; print; exit }' "$TMP/argv")"
check "the command is sync-config against VAULT_DIR" \
  "sync-config /data/vaults/testvault" \
  "$(head -1 "$TMP/argv") $(awk '/^--path$/ { getline; print; exit }' "$TMP/argv")"

echo "--- every default category is one the pinned CLI accepts ---"

# A drift guard against the real dependency, not a source regex over our own
# code: an invalid member makes `ob sync-config` reject the ENTIRE call, taking
# the conflict strategy down with the categories. The accepted set is read from
# the installed CLI's own --help output.
if command -v ob >/dev/null 2>&1; then
  ob_valid="$(ob sync-config --help 2>&1 | tr '\n' ' ' | tr -s ' ' \
              | grep -o 'Config categories to sync, comma-separated:[^(]*' \
              | sed 's/.*comma-separated: //')"
  unknown=""
  for cat in $(printf '%s' "$ALL8" | tr ',' ' '); do
    case ",$(printf '%s' "$ob_valid" | tr -d ' ')," in
      *",$cat,"*) ;;
      *) unknown="$unknown $cat" ;;
    esac
  done
  check "no default category is unknown to the installed ob" "" "$unknown"
  check "the accepted set was actually read (guard is not vacuously empty)" \
    "yes" "$([ -n "$ob_valid" ] && echo yes || echo no)"
else
  # Environment precondition: obsidian-headless is not installed in this
  # checkout. Nothing about the daemon is being excused.
  echo "skip - 'ob' is not installed here; cannot read the CLI's accepted category set"
fi

echo "--- VAULT_SYNC_CONFIGS still overrides ---"

state="$(run_apply set "app,appearance")"
check "an explicit narrower list is passed through verbatim" \
  "app,appearance" "$(configs_arg)"
check "the override is logged too" \
  "1" "$(grep -c 'carry config categories: app,appearance$' "$TMP/log")"
check "an overridden successful call still records state ok" "ok" "$state"

state="$(run_apply set "$ALL8")"
check "an explicit full list is passed through verbatim" "$ALL8" "$(configs_arg)"

echo "--- an explicitly empty value means OFF, not the default ---"

state="$(run_apply empty)"
check "VAULT_SYNC_CONFIGS= passes --configs with an empty value, ob's own clear" \
  "<EMPTY>" "$(configs_arg)"
check "the empty case warns that devices will receive no config" \
  "1" "$(grep -c 'Obsidian Sync will carry NO .obsidian/ config' "$TMP/log")"
check "the empty case does not claim to be carrying categories" \
  "0" "$(grep -c 'carry config categories' "$TMP/log")"

echo "--- a failed sync-config is loud, not silent ---"

state="$(run_apply unset "" 1)"
check "a failing sync-config records state FAILED" "FAILED" "$state"
check "a failing sync-config warns that categories are unchanged" \
  "1" "$(grep -c 'WARNING: sync-config failed - conflict strategy AND config categories are unchanged' "$TMP/log")"
check "the failure warning says devices may receive no config" \
  "1" "$(grep -c 'may receive no .obsidian/ config' "$TMP/log")"

echo "--- an ALREADY-LINKED vault gets the config too ---"

# ensure_ob_setup returns early when `sync-status` succeeds. Before this change
# the sync-config call lived below that early return, so a vault linked under an
# older default could never be healed by a redeploy - it would keep its original
# settings forever while the deploy looked like it had applied them.
{
  harness
  cat <<'LINKED'
SYNC_REMOTE="ignored"; SYNC_ENC_PW=""; DEVICE_NAME="d"
ob_v() { printf 'SETUP-RAN\n' >> "$ARGV_FILE"; return 0; }
LINKED
  echo 'env -u VAULT_SYNC_CONFIGS true'
  extract_fn ensure_ob_setup
  echo 'ensure_ob_setup >/dev/null 2>&1; printf "%s" "$?"'
} > "$TMP/linked.sh"
rc="$(env -u VAULT_SYNC_CONFIGS bash "$TMP/linked.sh")"

check "ensure_ob_setup still succeeds for an already-linked vault" "0" "$rc"
check "the already-linked path did NOT re-run sync-setup" \
  "0" "$(grep -c '^SETUP-RAN$' "$TMP/argv")"
check "the already-linked path DID run sync-config" \
  "1" "$(grep -c '^sync-config$' "$TMP/argv")"
check "the already-linked path applied the full default category list" \
  "$ALL8" "$(configs_arg)"

echo "--- the heartbeat reports the config decision ---"

# The heartbeat line is executed verbatim from bridge.sh, so a format change
# that drops the categories fails here rather than passing a regex.
{
  cat <<'HB'
set -u
CURRENT_INTERVAL=15; HAVE_OB=1
hb_head=abc1234; hb_dirty=0; hb_obq=12
NAME=testvault
log() { printf '%s\n' "$*"; }
HB
  extract_line 'SYNC_CONFIGS_DEFAULT='
  extract_line 'SYNC_CONFIGS='
  echo 'SYNC_CONFIGS_STATE="ok"'
  grep -m1 '^      log "heartbeat: ' "$BRIDGE" | sed 's/^ *//'
} > "$TMP/hb.sh"
hb="$(env -u VAULT_SYNC_CONFIGS bash "$TMP/hb.sh")"

check "the heartbeat names the applied category list" \
  "1" "$(printf '%s' "$hb" | grep -c "configs=ok:$ALL8")"
check "the heartbeat still carries the pre-existing git-level fields" \
  "1" "$(printf '%s' "$hb" | grep -c 'HEAD=abc1234 uncommitted=0')"


echo "--- attachment types: carried by default, narrowable, clearable ---"

ALL5="image,audio,video,pdf,unsupported"

{ harness; echo 'apply_sync_config'; } | env -i bash /dev/stdin
check "--file-types is passed at all" "1" "$(grep -c -- '^--file-types$' "$TMP/argv")"
check "the default carries all five attachment types" "$ALL5" "$(filetypes_arg)"
check "the choice is answerable from the logs" "1" \
  "$(grep -c "attachment types: $ALL5" "$TMP/log")"

{ harness; echo 'apply_sync_config'; } | env -i VAULT_SYNC_FILE_TYPES="image,pdf" bash /dev/stdin
check "VAULT_SYNC_FILE_TYPES narrows the list" "image,pdf" "$(filetypes_arg)"

{ harness; echo 'apply_sync_config'; } | env -i VAULT_SYNC_FILE_TYPES= bash /dev/stdin
check "explicit-empty means markdown only, not the default" "<EMPTY>" "$(filetypes_arg)"
check "and warns that Sync will carry markdown ONLY" "1" \
  "$(grep -c 'markdown ONLY' "$TMP/log")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

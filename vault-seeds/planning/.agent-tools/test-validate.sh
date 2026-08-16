#!/usr/bin/env bash
# Behavioural tests for validate-notes.py: builds real fixture vaults under a
# temp dir and runs the validator against each. PASS/FAIL counts, non-zero
# exit if anything failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-notes.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; echo "  -- $2"; }

# A minimal, fully-valid vault: two ideas linking each other, an INDEX row
# pointing at a real area file, that area file linking back folder-qualified.
make_base_vault() {
  local dir="$1"
  mkdir -p "$dir"/inbox "$dir"/ideas "$dir"/archive \
           "$dir"/.agent-memory/areas/foo "$dir"/.agent-memory/sessions

  cat > "$dir/ideas/valid.md" <<'EOF'
---
title: A valid idea
state: not-started
created: 2026-08-14
---
This idea references [[ideas/other]] for context.
EOF

  cat > "$dir/ideas/other.md" <<'EOF'
---
title: Other idea
state: not-started
---
Body text. [[ideas/valid]]
EOF

  cat > "$dir/inbox/README.md" <<'EOF'
# inbox/

Documentation only, not an idea note - no frontmatter on purpose.
EOF

  cat > "$dir/.agent-memory/INDEX.md" <<'EOF'
---
type: memory-index
updated: 2026-08-16
---
# Agent memory index

| area | scope | memory | updated |
|---|---|---|---|
| foo | ideas/** | areas/foo/memory.md | 2026-08-16 |
EOF

  cat > "$dir/.agent-memory/areas/foo/memory.md" <<'EOF'
---
type: area-memory
area: foo
scope: ideas/**
updated: 2026-08-16
---
# foo memory

Refers to [[ideas/valid]].
EOF
}

run_case() {
  # run_case NAME DIR WANT_EXIT [GREP_SUBSTRING]
  local name="$1" dir="$2" want_exit="$3" grep_for="${4:-}"
  local out code
  out="$(python3 "$VALIDATE" "$dir" 2>&1)"
  code=$?
  if [ "$code" -ne "$want_exit" ]; then
    fail "$name" "expected exit $want_exit, got $code
--- output ---
$out"
    return
  fi
  if [ -n "$grep_for" ] && ! grep -qF "$grep_for" <<<"$out"; then
    fail "$name" "expected output to contain: $grep_for
--- output ---
$out"
    return
  fi
  pass "$name"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. valid note passes
make_base_vault "$TMP/valid"
run_case "valid vault passes clean" "$TMP/valid" 0

# 2. missing state fails
make_base_vault "$TMP/missing-state"
cat > "$TMP/missing-state/ideas/bad.md" <<'EOF'
---
title: Missing state
---
Body [[ideas/valid]]
EOF
run_case "missing state fails" "$TMP/missing-state" 1 "missing required field 'state'"

# 3. bad state value fails
make_base_vault "$TMP/bad-state"
cat > "$TMP/bad-state/ideas/bad.md" <<'EOF'
---
title: Bad state value
state: maybe-someday
---
Body [[ideas/valid]]
EOF
run_case "bad state value fails" "$TMP/bad-state" 1 "not one of"

# 4. unresolvable depends_on fails
make_base_vault "$TMP/unresolved-dep"
cat > "$TMP/unresolved-dep/ideas/bad.md" <<'EOF'
---
title: Unresolvable dependency
state: not-started
depends_on: ["[[Nonexistent Idea]]"]
---
Body [[ideas/valid]]
EOF
run_case "unresolvable depends_on fails" "$TMP/unresolved-dep" 1 "does not resolve"

# 5. unquoted [[dep]] fails
make_base_vault "$TMP/unquoted-dep"
cat > "$TMP/unquoted-dep/ideas/bad.md" <<'EOF'
---
title: Unquoted dependency
state: not-started
depends_on: [[[ideas/valid]]]
---
Body text.
EOF
run_case "unquoted [[dep]] fails" "$TMP/unquoted-dep" 1 "not a quoted wikilink"

# 6. INDEX row pointing at missing file fails
make_base_vault "$TMP/index-missing"
cat > "$TMP/index-missing/.agent-memory/INDEX.md" <<'EOF'
---
type: memory-index
updated: 2026-08-16
---
# Agent memory index

| area | scope | memory | updated |
|---|---|---|---|
| foo | ideas/** | areas/foo/memory.md | 2026-08-16 |
| ghost | ideas/** | areas/ghost/memory.md | 2026-08-16 |
EOF
run_case "INDEX row pointing at missing file fails" "$TMP/index-missing" 1 "does not exist"

# 7. area file without INDEX row fails
make_base_vault "$TMP/area-no-row"
mkdir -p "$TMP/area-no-row/.agent-memory/areas/orphan"
cat > "$TMP/area-no-row/.agent-memory/areas/orphan/memory.md" <<'EOF'
---
type: area-memory
area: orphan
scope: nowhere/**
updated: 2026-08-16
---
# orphan memory
EOF
run_case "area file without INDEX row fails" "$TMP/area-no-row" 1 "no INDEX row references"

# 8. non-folder-qualified memory link fails
make_base_vault "$TMP/bad-memlink"
cat > "$TMP/bad-memlink/.agent-memory/areas/foo/memory.md" <<'EOF'
---
type: area-memory
area: foo
scope: ideas/**
updated: 2026-08-16
---
# foo memory

Refers to [[valid]].
EOF
run_case "non-folder-qualified memory link fails" "$TMP/bad-memlink" 1 "not folder-qualified"

# 9. zero-link idea warns but exits 0 when only warnings
make_base_vault "$TMP/warn-only"
cat > "$TMP/warn-only/ideas/lonely.md" <<'EOF'
---
title: Lonely idea
state: not-started
---
No links here at all, and no marker either.
EOF
run_case "zero-link idea warns but exits 0" "$TMP/warn-only" 0 "zero outgoing"

# 10. "no genuine relation found" marker suppresses the warning (exit 0, no warning text)
make_base_vault "$TMP/marker-ok"
cat > "$TMP/marker-ok/ideas/lonely-but-marked.md" <<'EOF'
---
title: Lonely but searched
state: not-started
---
Searched the corpus - no genuine relation found.
EOF
run_case "marked no-relation idea does not warn" "$TMP/marker-ok" 0

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

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
           "$dir"/.agent-memory/areas/foo "$dir"/.agent-memory/sessions \
           "$dir"/.cursor/rules

  # Corpus marker: the floor schema (title/state, connect step, enrichment)
  # only applies to vaults carrying the idea-notes rule. Fixtures are corpus
  # vaults so those checks stay exercised.
  echo "# fixture corpus marker" > "$dir/.cursor/rules/idea-notes.mdc"

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

# 11. a note outside inbox/ideas/archive (folders carry no semantics - any
# location is scanned) with a bad state still fails.
make_base_vault "$TMP/anywhere-bad"
mkdir -p "$TMP/anywhere-bad/projects/quantsoc"
cat > "$TMP/anywhere-bad/projects/quantsoc/loose-note.md" <<'EOF'
---
title: A note filed nowhere special
state: maybe-someday
---
Body [[ideas/valid]]
EOF
run_case "note outside the old note-dirs is still scanned" "$TMP/anywhere-bad" 1 "not one of"

# 12. Dashboard/ and _templates/ are never scanned for floor schema, even
# though they hold .md files with no frontmatter.
make_base_vault "$TMP/dashboard-skip"
mkdir -p "$TMP/dashboard-skip/Dashboard" "$TMP/dashboard-skip/_templates"
cat > "$TMP/dashboard-skip/Dashboard/Notes.md" <<'EOF'
# Not an idea note, no frontmatter at all.
EOF
cat > "$TMP/dashboard-skip/_templates/idea.md" <<'EOF'
---
title:
state: not-started
---
Template body.
EOF
run_case "Dashboard/ and _templates/ are excluded from the floor-schema check" "$TMP/dashboard-skip" 0

# 13. --enrich-list prints notes missing the floor schema and exits 0 (a
# report, not a gate) - the automatic-enrichment obligation's data source.
make_base_vault "$TMP/enrich-list"
cat > "$TMP/enrich-list/ideas/needs-enrichment.md" <<'EOF'
Just a capture with no frontmatter at all.
EOF
out="$(python3 "$VALIDATE" "$TMP/enrich-list" --enrich-list 2>&1)"
code=$?
if [ "$code" -eq 0 ] && grep -qF "ideas/needs-enrichment.md" <<<"$out"; then
  pass "--enrich-list finds a note missing the floor schema"
else
  fail "--enrich-list finds a note missing the floor schema" "exit=$code
--- output ---
$out"
fi

# 14. --enrich-list is silent (and still exit 0) over a fully-enriched vault.
make_base_vault "$TMP/enrich-list-clean"
out="$(python3 "$VALIDATE" "$TMP/enrich-list-clean" --enrich-list 2>&1)"
code=$?
if [ "$code" -eq 0 ] && [ -z "$out" ]; then
  pass "--enrich-list is silent over a fully-enriched vault"
else
  fail "--enrich-list is silent over a fully-enriched vault" "exit=$code
--- output ---
$out"
fi

# 15. NON-CORPUS vault (no idea-notes.mdc): documents without frontmatter are
# fine, no connect warning, --enrich-list is empty - the floor schema is the
# planning-corpus contract, never imposed on a document vault. Universal checks
# still hold: a state field that IS present must use the enum.
make_base_vault "$TMP/document-vault"
rm "$TMP/document-vault/.cursor/rules/idea-notes.mdc"
mkdir -p "$TMP/document-vault/notes"
cat > "$TMP/document-vault/notes/lecture.md" <<'EOF'
# Lecture 4 - Databases

Plain document, no frontmatter, no wikilinks. Perfectly fine here.
EOF
run_case "document vault: bare .md passes with no warnings" "$TMP/document-vault" 0
out="$(python3 "$VALIDATE" "$TMP/document-vault" 2>&1)"
if grep -q "zero outgoing" <<<"$out"; then
  fail "document vault: no connect-step warning" "warned anyway
--- output ---
$out"
else
  pass "document vault: no connect-step warning"
fi
out="$(python3 "$VALIDATE" "$TMP/document-vault" --enrich-list 2>&1)"
code=$?
if [ "$code" -eq 0 ] && [ -z "$out" ]; then
  pass "document vault: --enrich-list is empty (enrichment never fires)"
else
  fail "document vault: --enrich-list is empty (enrichment never fires)" "exit=$code
--- output ---
$out"
fi

# 16. NON-CORPUS vault: a present-but-invalid state still fails (the enum is
# universal wherever the field exists).
make_base_vault "$TMP/document-vault-badstate"
rm "$TMP/document-vault-badstate/.cursor/rules/idea-notes.mdc"
cat > "$TMP/document-vault-badstate/tracked.md" <<'EOF'
---
title: Opted into state tracking
state: someday
---
Body.
EOF
run_case "document vault: invalid state value still fails" "$TMP/document-vault-badstate" 1 "not one of"

# 17. A folder NAMED Dashboard, nested anywhere, must NOT exempt a real note.
# The skip is for two specific top-level directories; matching the name at any
# depth let a note evade every check by where it sat - the exact folder-carries-
# meaning behaviour this vault does not have.
make_base_vault "$TMP/nested-dashboard"
mkdir -p "$TMP/nested-dashboard/projects/sub/Dashboard"
cat > "$TMP/nested-dashboard/projects/sub/Dashboard/sneaky.md" <<'EOF'
---
title: Hiding in a folder called Dashboard
state: not-a-real-state
---
Body [[ideas/valid]]
EOF
run_case "a note under a NESTED folder named Dashboard is still checked" "$TMP/nested-dashboard" 1 "not one of"

# 18. The real top-level Dashboard/ is still exempt (the skip must still work).
make_base_vault "$TMP/root-dashboard"
mkdir -p "$TMP/root-dashboard/Dashboard"
cat > "$TMP/root-dashboard/Dashboard/view.md" <<'EOF'
# A dashboard view, no frontmatter by design.
EOF
run_case "the real top-level Dashboard/ is still exempt" "$TMP/root-dashboard" 0

# 19. Uppercase .MD is a note on macOS/Windows and was never scanned at all.
make_base_vault "$TMP/upper-ext"
cat > "$TMP/upper-ext/ideas/upper.MD" <<'EOF'
---
title: Upper case extension
state: bogus-state
---
Body [[ideas/valid]]
EOF
run_case "an uppercase .MD note is scanned like any other" "$TMP/upper-ext" 1 "not one of"

# 20. depends_on may carry Obsidian's #heading and ^block anchors; both name the
# same note and must resolve rather than being reported unresolvable.
make_base_vault "$TMP/anchors"
cat > "$TMP/anchors/ideas/anchored.md" <<'EOF'
---
title: Anchored dependency
state: not-started
depends_on: ["[[ideas/valid#Some Heading]]", "[[ideas/other^abcd12]]"]
---
Body [[ideas/valid]]
EOF
run_case "depends_on accepts #heading and ^block anchors" "$TMP/anchors" 0

# 21. A duplicate top-level key silently discarded the first value.
make_base_vault "$TMP/dupkey"
cat > "$TMP/dupkey/ideas/dup.md" <<'EOF'
---
title: First title
title: Second title
state: not-started
---
Body [[ideas/valid]]
EOF
run_case "a duplicate frontmatter key is an error, not a silent overwrite" "$TMP/dupkey" 1 "duplicate frontmatter key"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]

#!/usr/bin/env python3
"""Vault note/memory validator - the one enforcement mechanism for the floor schema.

Folders carry ZERO semantics in this vault (see idea-notes.mdc): a note can live
anywhere and is never relocated. So this validator scans every .md file in the
vault, wherever it sits, except: dotfolders (.git .obsidian .agent-tools .claude
.cursor .agent-memory - the last has its own schema, enforced by checks 4-5
below, not the idea floor schema), Dashboard/ (views/docs, not notes),
_templates/ (templates, not real notes), and any file named README.md (vault
documentation, not an idea note).

Checks (see idea-notes.mdc / agent-memory.md for the rules these enforce):
  1. CORPUS VAULTS ONLY (vaults carrying .cursor/rules/idea-notes.mdc): every
     scanned .md has frontmatter with title + state, state in {not-started,
     started, done, dropped}. A note missing this is "missing metadata" - not an
     error to fix by moving it anywhere, an error to fix by adding the
     frontmatter in place (enrichment; see --enrich-list below). Vaults without
     that rule (document vaults) skip this and the connect-step warning; the
     state enum is still enforced wherever a state field IS present.
  2. depends_on entries, when present, are quoted wikilinks "[[...]]" and resolve
     to an existing note (path or basename, .md optional) anywhere in the vault.
  3. Frontmatter parses at all - a tolerant hand-rolled checker (stdlib only, no
     PyYAML) that catches the two documented traps: unquoted [[..]] eaten as a
     YAML flow sequence, and a bare leading '*' (YAML alias syntax).
  4. .agent-memory/INDEX.md rows resolve to real files, and every
     areas/*/memory.md on disk has a row (checked both directions).
  5. Wikilinks inside .agent-memory/** are folder-qualified (contain a '/'),
     per the memory rules.
  6. Warnings (do not fail the run): a note with zero outgoing [[links]] and no
     "no genuine relation found" marker (the connect step); any file >4.5MB
     outside .git (approaching the 5MB sync cap).

Usage, from anywhere (path is derived from this script's own location, or pass
an explicit vault root):
  python3 .agent-tools/validate-notes.py             # report problems, exit 1 if any
  python3 .agent-tools/validate-notes.py --quiet      # errors only, minimal output, for hooks
  python3 .agent-tools/validate-notes.py --enrich-list  # list notes missing the floor
                                                         # schema (title/state), one path
                                                         # per line, for the enrichment
                                                         # obligation in idea-notes.mdc
  python3 .agent-tools/validate-notes.py /path/vault  # explicit root (used by tests)

Deliberately does not check anything beyond the items above. Do not extend this
file's checks without updating the ratified enforcement list it implements.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parent.parent

# The floor schema (title/state) is the PLANNING CORPUS contract, declared by the
# presence of the idea-notes rule in the vault being validated. A vault without
# it (e.g. a personal document vault) gets only the universal checks: YAML traps,
# state-enum-if-present, memory-file consistency, folder-qualified memory links,
# and the size cap. Documents are not ideas.
def is_corpus(root: Path) -> bool:
    return (root / ".cursor" / "rules" / "idea-notes.mdc").is_file()

SKIP_DIR_NAMES = {
    ".git", ".obsidian", ".agent-tools", ".claude", ".cursor", ".agent-memory",
    "Dashboard", "_templates",
}
VALID_STATES = {"not-started", "started", "done", "dropped"}
MAX_BYTES = int(4.5 * 1024 * 1024)

FM_UNTERMINATED = object()  # sentinel: opened with '---' but never closed

WIKILINK_QUOTED_RE = re.compile(r'^(["\'])\[\[(.+?)\]\]\1$')
WIKILINK_ANY_RE = re.compile(r"\[\[([^\[\]]+)\]\]")
TOP_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")


# --------------------------------------------------------------------------
# generic helpers
# --------------------------------------------------------------------------

def should_skip(path: Path, root: Path) -> bool:
    rel_parts = path.relative_to(root).parts
    if any(p in SKIP_DIR_NAMES for p in rel_parts):
        return True
    # Root-level docs only. Scoping this matters: an unscoped name-based skip
    # would let any note anywhere evade every check just by being called
    # README.md, in a vault whose premise is that names and folders carry no
    # meaning. A README.md deeper in the tree is documentation for its own
    # folder and still skipped; AGENTS.md is generated and only valid at root.
    rel = path.relative_to(root)
    if path.name.lower() == "readme.md":
        return True
    if path.name.lower() == "agents.md" and len(rel.parts) == 1:
        return True
    return False


def strip_scalar(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")


# --------------------------------------------------------------------------
# frontmatter extraction + tolerant parsing
# --------------------------------------------------------------------------

def extract_frontmatter_block(text: str):
    """Returns (raw_frontmatter_or_sentinel_or_None, body)."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), "\n".join(lines[i + 1:])
    return FM_UNTERMINATED, text


def parse_frontmatter_lines(raw_lines: list[str]):
    """Tolerant top-level key/value parser.

    Returns (fields, errors) where fields maps key -> {"inline": str, "block": [str]}.
    Only top-level (column-0) lines start a new key; indented lines are treated
    as continuation (block-list items) of the current key.
    """
    fields: dict[str, dict] = {}
    errors: list[str] = []
    current = None
    for lineno, line in enumerate(raw_lines, start=1):
        if not line.strip() or line.strip().startswith("#"):
            continue
        if line[0] not in (" ", "\t"):
            m = TOP_KEY_RE.match(line)
            if not m:
                errors.append(f"line {lineno}: unparseable frontmatter line: {line!r}")
                current = None
                continue
            key, inline = m.group(1), m.group(2).rstrip()
            fields[key] = {"inline": inline, "block": []}
            current = key
            if inline.lstrip().startswith("*"):
                errors.append(
                    f"field '{key}': value starts with a bare '*' (YAML alias syntax) - quote it"
                )
        else:
            if current is None:
                errors.append(f"line {lineno}: indented line with no preceding key: {line!r}")
                continue
            fields[current]["block"].append(line.strip())
    return fields, errors


def split_flow_list(s: str) -> list[str]:
    """Split a YAML flow-list interior (already stripped of outer [ ]) on
    top-level commas, respecting quotes and nested brackets."""
    items: list[str] = []
    cur = ""
    depth = 0
    in_quote = None
    for ch in s:
        if in_quote:
            cur += ch
            if ch == in_quote:
                in_quote = None
            continue
        if ch in ('"', "'"):
            in_quote = ch
            cur += ch
            continue
        if ch == "[":
            depth += 1
            cur += ch
            continue
        if ch == "]":
            depth -= 1
            cur += ch
            continue
        if ch == "," and depth == 0:
            items.append(cur.strip())
            cur = ""
            continue
        cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


def get_list_items(fields: dict, key: str) -> list[str]:
    if key not in fields:
        return []
    info = fields[key]
    items: list[str] = []
    inline = info["inline"].strip()
    if inline and inline != "[]":
        if inline.startswith("[") and inline.endswith("]"):
            items.extend(split_flow_list(inline[1:-1]))
        else:
            items.append(inline)
    for b in info["block"]:
        if b.startswith("- "):
            items.append(b[2:].strip())
        elif b == "-":
            continue
        else:
            items.append(b)
    return items


def check_depends_on_item(item: str):
    """Returns (target_or_None, error_or_None)."""
    m = WIKILINK_QUOTED_RE.match(item)
    if not m:
        return None, f'depends_on entry not a quoted wikilink: {item!r} (expected "[[Note Name]]")'
    target = m.group(2).split("|", 1)[0].strip()
    return target, None


# --------------------------------------------------------------------------
# note index (for depends_on resolution) - vault-wide, folders carry no meaning
# --------------------------------------------------------------------------

def iter_note_files(root: Path):
    for p in sorted(root.rglob("*.md")):
        if should_skip(p, root):
            continue
        yield p


def build_note_index(root: Path) -> dict[str, list[Path]]:
    index: dict[str, list[Path]] = {}
    for p in iter_note_files(root):
        rel_noext = str(p.relative_to(root).with_suffix(""))
        index.setdefault(rel_noext, []).append(p)
        index.setdefault(p.stem, []).append(p)
    return index


def resolve_target(target: str, note_index: dict[str, list[Path]]) -> bool:
    t = target.strip()
    if t.endswith(".md"):
        t = t[:-3]
    return t in note_index


# --------------------------------------------------------------------------
# floor-schema inspection, shared by the strict checker and --enrich-list
# --------------------------------------------------------------------------

def read_floor_schema(p: Path):
    """Returns (fm_raw, body, fields, parse_errors, title, state_present, state_val)."""
    text = read_text(p)
    fm_raw, body = extract_frontmatter_block(text)
    if fm_raw is None or fm_raw is FM_UNTERMINATED:
        return fm_raw, body, {}, [], "", False, ""
    fields, parse_errors = parse_frontmatter_lines(fm_raw.split("\n"))
    title = strip_scalar(fields.get("title", {}).get("inline", ""))
    state_present = "state" in fields and bool(fields["state"]["inline"].strip())
    state_val = strip_scalar(fields["state"]["inline"].split("#", 1)[0]) if state_present else ""
    return fm_raw, body, fields, parse_errors, title, state_present, state_val


# --------------------------------------------------------------------------
# check 1-3 + 6a: per-note frontmatter and connect-step warning
# --------------------------------------------------------------------------

def check_notes(root: Path, note_index: dict[str, list[Path]]):
    errors: list[tuple[str, str]] = []
    warnings: list[tuple[str, str]] = []
    corpus = is_corpus(root)

    for p in iter_note_files(root):
        rel = str(p.relative_to(root))
        fm_raw, body, fields, parse_errors, title, state_present, state_val = read_floor_schema(p)

        if fm_raw is None:
            if corpus:
                errors.append((rel, "no YAML frontmatter block (file must start with '---' ... '---')"))
            continue
        if fm_raw is FM_UNTERMINATED:
            errors.append((rel, "frontmatter opened with '---' but never closed with a second '---'"))
            continue

        for e in parse_errors:
            errors.append((rel, f"frontmatter parse issue - {e}"))

        if corpus and not title:
            errors.append((rel, "frontmatter missing required field 'title'"))

        if corpus and not state_present:
            errors.append((rel, "frontmatter missing required field 'state'"))
        elif state_present and state_val not in VALID_STATES:
            errors.append((rel, f"state '{state_val}' is not one of {sorted(VALID_STATES)}"))

        for item in get_list_items(fields, "depends_on"):
            target, err = check_depends_on_item(item)
            if err:
                errors.append((rel, err))
                continue
            if not resolve_target(target, note_index):
                errors.append(
                    (rel, f"depends_on target does not resolve to an existing note: {target!r}")
                )

        # Connect step applies to every corpus note, wherever it lives - folders
        # don't distinguish "idea" from "capture" anymore. Document vaults are
        # not under the connect obligation, so no warning noise there.
        has_link = bool(WIKILINK_ANY_RE.search(body))
        has_marker = "no genuine relation" in body.lower()
        if corpus and not has_link and not has_marker:
            warnings.append(
                (rel, 'zero outgoing [[wikilinks]] and no "no genuine relation found" marker')
            )

    return errors, warnings


# --------------------------------------------------------------------------
# --enrich-list: notes missing the floor schema, for the automatic enrichment
# obligation in idea-notes.mdc (no pass/fail - a report, not a gate)
# --------------------------------------------------------------------------

def enrich_list(root: Path) -> list[str]:
    if not is_corpus(root):
        return []  # no floor schema, nothing to enrich - never fires on document vaults
    missing: list[str] = []
    for p in iter_note_files(root):
        _, _, _, _, title, state_present, state_val = read_floor_schema(p)
        if not title or not state_present or state_val not in VALID_STATES:
            missing.append(str(p.relative_to(root)))
    return missing


# --------------------------------------------------------------------------
# check 4: .agent-memory/INDEX.md rows vs areas/*/memory.md on disk
# --------------------------------------------------------------------------

def parse_index_table(index_path: Path):
    lines = read_text(index_path).splitlines()
    header_idx = None
    for i, line in enumerate(lines):
        low = line.strip().lower()
        if low.startswith("|") and "area" in low and "memory" in low:
            header_idx = i
            break
    if header_idx is None:
        return [], ["INDEX.md: no table header row found (expected '| area | scope | memory | updated |')"]

    header_cells = [c.strip().lower() for c in lines[header_idx].strip().strip("|").split("|")]
    if "memory" not in header_cells:
        return [], ["INDEX.md: table has no 'memory' column"]
    memory_col = header_cells.index("memory")

    rows = []
    for line in lines[header_idx + 1:]:
        s = line.strip()
        if not s.startswith("|"):
            break
        if set(s.replace("|", "").strip()) <= {"-", " "}:
            continue  # the '|---|---|' separator row
        cells = [c.strip() for c in s.strip("|").split("|")]
        if len(cells) > memory_col and cells[memory_col]:
            rows.append(cells[memory_col])
    return rows, []


def resolve_index_memory_path(root: Path, cell: str):
    cell = cell.strip().strip("`")
    for candidate in (root / ".agent-memory" / cell, root / cell):
        if candidate.is_file():
            return candidate
    return None


def check_index(root: Path):
    errors: list[tuple[str, str]] = []
    index_path = root / ".agent-memory" / "INDEX.md"
    label = str(index_path.relative_to(root)) if index_path.exists() else ".agent-memory/INDEX.md"

    if not index_path.is_file():
        return [(label, "file missing")]

    rows, header_errors = parse_index_table(index_path)
    for e in header_errors:
        errors.append((label, e))

    resolved_paths = set()
    for cell in rows:
        resolved = resolve_index_memory_path(root, cell)
        if resolved is None:
            errors.append((label, f"row references memory file that does not exist: {cell!r}"))
        else:
            resolved_paths.add(resolved.resolve())

    areas_dir = root / ".agent-memory" / "areas"
    if areas_dir.is_dir():
        for f in sorted(areas_dir.glob("*/memory.md")):
            if f.resolve() not in resolved_paths:
                rel = f.relative_to(root)
                errors.append((label, f"no INDEX row references existing area file {rel}"))

    return errors


# --------------------------------------------------------------------------
# check 5: memory wikilinks must be folder-qualified
# --------------------------------------------------------------------------

def strip_code_blocks(text: str) -> str:
    """Blank out fenced (```/~~~) and indented (4+ space) code blocks, keeping
    line count and offsets intact, so format-example syntax like the
    literal `[[source or session]]` placeholder in a template line isn't
    mistaken for a real link to resolve."""
    lines = text.split("\n")
    out = []
    in_fence = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            out.append("")
            continue
        if in_fence:
            out.append("")
            continue
        if re.match(r"^ {4,}\S", line) or line.startswith("\t"):
            out.append("")
            continue
        # Inline code spans are format-mentions too (`[[wikilinks]]` as prose);
        # blank them with same-length padding so line numbers stay accurate.
        line = re.sub(r"`[^`\n]+`", lambda m: " " * len(m.group(0)), line)
        out.append(line)
    return "\n".join(out)


def check_memory_links(root: Path):
    errors: list[tuple[str, str]] = []
    mem_dir = root / ".agent-memory"
    if not mem_dir.is_dir():
        return errors
    for p in sorted(mem_dir.rglob("*.md")):
        text = read_text(p)
        scan_text = strip_code_blocks(text)
        for m in WIKILINK_ANY_RE.finditer(scan_text):
            target = m.group(1).split("|", 1)[0].strip()
            target = strip_scalar(target)
            if "/" not in target:
                rel = p.relative_to(root)
                lineno = text.count("\n", 0, m.start()) + 1
                errors.append(
                    (f"{rel}:{lineno}",
                     f"wikilink not folder-qualified: [[{target}]] "
                     f"(memory links must include a '/', e.g. [[ideas/Note Name]])")
                )
    return errors


# --------------------------------------------------------------------------
# check 6b: large files
# --------------------------------------------------------------------------

def check_file_sizes(root: Path):
    warnings: list[tuple[str, str]] = []
    for p in root.rglob("*"):
        if not p.is_file() or should_skip(p, root):
            continue
        try:
            size = p.stat().st_size
        except OSError:
            continue
        if size > MAX_BYTES:
            rel = p.relative_to(root)
            warnings.append(
                (str(rel), f"file is {size / 1024 / 1024:.2f}MB, approaching the 5MB sync cap")
            )
    return warnings


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main() -> int:
    argv = sys.argv[1:]
    quiet = "--quiet" in argv
    do_enrich_list = "--enrich-list" in argv
    positional = [a for a in argv if not a.startswith("--")]
    root = Path(positional[0]).resolve() if positional else DEFAULT_ROOT

    if not root.is_dir():
        print(f"vault root not found: {root}", file=sys.stderr)
        return 2

    if do_enrich_list:
        for rel in enrich_list(root):
            print(rel)
        return 0

    note_index = build_note_index(root)
    note_errors, note_warnings = check_notes(root, note_index)
    index_errors = check_index(root)
    memlink_errors = check_memory_links(root)
    size_warnings = check_file_sizes(root)

    errors = note_errors + index_errors + memlink_errors
    warnings = note_warnings + size_warnings

    if quiet:
        for path, msg in errors:
            print(f"[ERROR] {path}: {msg}")
        return 1 if errors else 0

    for path, msg in errors:
        print(f"[ERROR] {path}: {msg}")
    for path, msg in warnings:
        print(f"[WARN] {path}: {msg}")
    print()
    print(f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

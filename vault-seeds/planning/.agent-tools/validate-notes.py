#!/usr/bin/env python3
"""Vault note/memory validator - the one enforcement mechanism for the floor schema.

Checks (see idea-notes.mdc / agent-memory.md for the rules these enforce):
  1. Every .md under inbox/ ideas/ archive/ has frontmatter with title + state,
     state in {not-started, started, done, dropped}. (README.md files in those
     folders are vault documentation, not idea notes, and are skipped.)
  2. depends_on entries, when present, are quoted wikilinks "[[...]]" and resolve
     to an existing note (path or basename, .md optional).
  3. Frontmatter parses at all - a tolerant hand-rolled checker (stdlib only, no
     PyYAML) that catches the two documented traps: unquoted [[..]] eaten as a
     YAML flow sequence, and a bare leading '*' (YAML alias syntax).
  4. .agent-memory/INDEX.md rows resolve to real files, and every
     areas/*/memory.md on disk has a row (checked both directions).
  5. Wikilinks inside .agent-memory/** are folder-qualified (contain a '/'),
     per the memory rules.
  6. Warnings (do not fail the run): an ideas/ note with zero outgoing
     [[links]] and no "no genuine relation found" marker; any file >4.5MB
     outside .git (approaching the 5MB sync cap).

Usage, from anywhere (path is derived from this script's own location, or pass
an explicit vault root):
  python3 .agent-tools/validate-notes.py             # report problems, exit 1 if any
  python3 .agent-tools/validate-notes.py --quiet      # errors only, minimal output, for hooks
  python3 .agent-tools/validate-notes.py /path/vault  # explicit root (used by tests)

Deliberately does not check anything beyond the six items above. Do not extend
this file's checks without updating the ratified enforcement list it implements.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parent.parent

NOTE_DIRS = ("inbox", "ideas", "archive")
SKIP_DIR_NAMES = {".git", ".obsidian", ".agent-tools", ".claude", ".cursor"}
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
    if len(rel_parts) >= 2 and rel_parts[0] == "Dashboard" and path.suffix == ".base":
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
# note index (for depends_on resolution)
# --------------------------------------------------------------------------

def iter_note_files(root: Path):
    for base in NOTE_DIRS:
        d = root / base
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*.md")):
            if should_skip(p, root):
                continue
            if p.name.lower() == "readme.md":
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
# check 1-3 + 6a: per-note frontmatter and connect-step warning
# --------------------------------------------------------------------------

def check_notes(root: Path, note_index: dict[str, list[Path]]):
    errors: list[tuple[str, str]] = []
    warnings: list[tuple[str, str]] = []

    for p in iter_note_files(root):
        rel = str(p.relative_to(root))
        text = read_text(p)
        fm_raw, body = extract_frontmatter_block(text)

        if fm_raw is None:
            errors.append((rel, "no YAML frontmatter block (file must start with '---' ... '---')"))
            continue
        if fm_raw is FM_UNTERMINATED:
            errors.append((rel, "frontmatter opened with '---' but never closed with a second '---'"))
            continue

        fields, parse_errors = parse_frontmatter_lines(fm_raw.split("\n"))
        for e in parse_errors:
            errors.append((rel, f"frontmatter parse issue - {e}"))

        title = strip_scalar(fields.get("title", {}).get("inline", ""))
        if not title:
            errors.append((rel, "frontmatter missing required field 'title'"))

        if "state" not in fields or not fields["state"]["inline"].strip():
            errors.append((rel, "frontmatter missing required field 'state'"))
        else:
            state_val = strip_scalar(fields["state"]["inline"].split("#", 1)[0])
            if state_val not in VALID_STATES:
                errors.append(
                    (rel, f"state '{state_val}' is not one of {sorted(VALID_STATES)}")
                )

        for item in get_list_items(fields, "depends_on"):
            target, err = check_depends_on_item(item)
            if err:
                errors.append((rel, err))
                continue
            if not resolve_target(target, note_index):
                errors.append(
                    (rel, f"depends_on target does not resolve to an existing note: {target!r}")
                )

        if p.parent.name == "ideas" or str(p.relative_to(root)).startswith("ideas" + "/"):
            has_link = bool(WIKILINK_ANY_RE.search(body))
            has_marker = "no genuine relation" in body.lower()
            if not has_link and not has_marker:
                warnings.append(
                    (rel, 'zero outgoing [[wikilinks]] and no "no genuine relation found" marker')
                )

    return errors, warnings


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
    positional = [a for a in argv if not a.startswith("--")]
    root = Path(positional[0]).resolve() if positional else DEFAULT_ROOT

    if not root.is_dir():
        print(f"vault root not found: {root}", file=sys.stderr)
        return 2

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

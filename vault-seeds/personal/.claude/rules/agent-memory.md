---
alwaysApply: false
paths: Notes/**,.agent-memory/**
---

# Agent memory

This vault carries two kinds of agent memory, both under the dotfolder `.agent-memory/` —
invisible to Obsidian's UI and to Obsidian Sync, carried only by git. Never move memory
content into a visible folder, and never treat a visible note as memory infrastructure.

## The two layers

**Episodic** — `.agent-memory/sessions/YYYY-MM-DD-<session>.md`. One file per session,
append-only, written by the session itself as it works. A running record of what happened,
never curated, never read by default. Read a specific one only when explicitly asked for
past-session context.

**Durable** — `.agent-memory/areas/<area-slug>/memory.md`, one per topic area, plus
`.agent-memory/GLOBAL.md` for facts that span areas. Curated, in-place-edited, small. This is
where current status, deadlines, open tasks, watch items, contacts, and completed history
live — read *before* acting on that area, updated *as* facts change, never left to drift.

## Cold start: read this first, always

Read `.agent-memory/INDEX.md` before anything else in this vault. It is a small routing
table — area slug, scope glob, memory file path, last-updated date — nothing else. Match your
task's path or topic against its `scope` globs; if one matches, read that area's `memory.md`
before you act. Skim `GLOBAL.md` too; it is small by construction. Do not read session logs
unless specifically asked for history — they are not part of the default read path.

No area matches and the task is genuinely durable and recurring? Create one (new
`areas/<slug>/memory.md` from the template below, plus its row in `INDEX.md`) rather than
letting the fact live nowhere or drift into GLOBAL by default.

## Area memory file shape

Frontmatter: `type: area-memory`, `area:`, `scope:` (the glob this file tracks), `updated:`,
`tags:`. Body, fixed headings, in this order: `Status`, `Key Facts`, `Key Deadlines`, `Open
Tasks`, `Watch Items / Open Questions`, `Contacts`, `Completed / Done`, `Source Notes`.

**Every fact in Key Facts and Key Deadlines carries its provenance and its as-of date** —
`(source: <office/doc/URL>, as of YYYY-MM-DD)`. A fact with no date is not durable memory,
it's a guess with a byline. Before acting on a fact whose date is older than the area's own
volatility warrants (a visa deadline sooner than a contact's email), re-verify or move it to
Watch Items — never act on a silently-aged fact.

## Writing to durable memory: targeted edits only, never a whole-file rewrite

Area `memory.md` files, `INDEX.md`, and `GLOBAL.md` are all in-place-edited, on purpose — a
single current-state note is the point. That means contention is real and is handled by
discipline, the same way `subagent-orchestration.mdc` handles it for code: **the smallest
matching edit only** — one checklist line, one bullet under an existing heading, one table
row — never a section or whole-file regeneration from a draft held in your own head. Re-read
the file immediately before writing if any time has passed since you last read it this turn.
Bump `updated:` on every edit. If your edit's anchor text no longer matches, the file changed
under you — re-read and retry the targeted edit; do not fall back to rewriting the file to
force it through.

Session logs stay append-only, one file per session, per the existing convention — this is
the same underlying rule (smallest edit, no stale whole-file rewrite) applied to a case where
structure alone already prevents collision.

## Compaction and staleness — no silent forgetting

When a section outgrows a few hundred lines, fold old entries into a dated one-line summary;
move truly dead detail to a visible `archive/` note or drop it only once nothing open still
depends on it. Never delete an open deadline, open task, or active contact to make room.

**No fact is ever auto-expired.** An aging fact moves to Watch Items as needing
reconfirmation and stays visible there until an agent actually reconfirms or supersedes it —
silently dropping an unresolved fact is the same offense `test-integrity.mdc` names for tests,
applied to memory.

Review is opportunistic: whenever you read an area file to act on it, you are already
obligated to check whether anything you're about to rely on needs reconfirming.

## Promotion between area and global

A fact that recurs across two or more areas moves to `GLOBAL.md`; a `GLOBAL.md` fact that
turns out to only ever matter to one area moves back down. Don't duplicate a fact into two
area files — promote it once, to the one place it belongs.

## Governance

Ordinary reads and writes under `.agent-memory/**` need no ratification — this is agent
infrastructure, the same bucket as `inbox/`/`ideas/` writes. Changing *this rule* follows the
vault's normal rule-change governance.
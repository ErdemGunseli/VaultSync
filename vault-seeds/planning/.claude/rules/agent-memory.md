---
paths: "**/*.md"
---

# Agent memory

SCOPE: `.agent-memory/` in the vault repo only. Never applies to a software repository
attached to the same session.

Both layers live under the dotfolder `.agent-memory/` — invisible to Obsidian's UI and Sync,
carried only by git. Never treat a visible note as memory infrastructure: no routing tables,
session logs, or staleness bookkeeping in the corpus, ever. **Memory holds the bookkeeping;
the corpus holds the knowledge.** Machinery stays hidden permanently; knowledge an agent
produces — a decision, a finding, a deadline the owner must meet, an approach that failed —
is *published* into the corpus (below), never buried where no phone can open it.

**Episodic** — `.agent-memory/sessions/YYYY-MM-DD-<session>.md`, one per session,
append-only, not read by default, cannot collide (a session names its own file). **Durable**
— `.agent-memory/areas/<slug>/memory.md`, one per topic, plus `GLOBAL.md` for facts spanning
areas; curated, in-place-edited, small.

## Cold start

Read `.agent-memory/INDEX.md` first, always. It's a routing table: area slug, routing keys,
memory file path, updated date. A routing key is a path glob only where a vault actually
files by taxonomy — this vault's folders carry zero semantics (`idea-notes.mdc`), so no
path glob discriminates anything here. Keys are the corpus's own `projects`/`domains` values
and topic words instead; at least one key per row must genuinely discriminate. Skim
`GLOBAL.md` too — small by construction.

No row matches? `rg` across `.agent-memory/**` for the topic before concluding nothing is
known — the INDEX is routing, not the only way in. Still nothing and the task is durable
and recurring: create `areas/<slug>/memory.md` plus its INDEX row, rather than letting the
fact drift into GLOBAL by default or live nowhere.

## Fact lines

Every Key Facts / Key Deadlines entry is one line, bi-temporal, sourced:

    - <slot> :: <value> | valid <YYYY-MM-DD>- | confirmed <YYYY-MM-DD> | [[source or session]]

`valid` is when the fact became/becomes true in the world; `confirmed` is when an agent last
verified it — git's own commit history is the transaction-time record on top of this, never
re-invent it with a second date. Re-confirming an unchanged value bumps `confirmed:` and
appends the session ref; it does not duplicate the line.

## Reconcile before writing a durable fact

Before appending, scan the area file for the same `<slot>`:

- **same slot, different value** → supersede: stamp the old line's end date, cut it under
  the fixed `## Superseded` heading with the date, note what replaced it.
- **same slot, same value** → don't duplicate: bump `confirmed:`, append the session ref.
- **same slot, both true at once** (a person speaks two languages; an address changed on a
  known date) → accrue: both lines stand, each dated — never let the guard against
  duplicates collapse two facts that hold simultaneously.
- **contradicts an existing fact and you can't tell which is right** → don't guess; add both
  to Watch Items with the disagreement stated, never silently pick one.
- no matching slot → append.

Compaction may fold old `Superseded` entries into a dated one-line summary; it may never
delete one that an open task, a Watch Item, or another note still references.

## Publishing to the corpus

Two questions decide whether something is memory or a note. Both must hold:

1. Would it still be worth keeping if the agent layer vanished tomorrow?
2. Can it be stated without naming an agent, a session, a rule, or a memory file?

Both yes → publish. Either no → stays in memory. Routing rows, session logs, staleness
flags, coverage lists and standing agent preferences fail #2 and never leave
`.agent-memory/`. Decisions, findings, dead ends and the owner's own deadlines pass both.

- Concerns **one** note → append it there under a `## Decisions` heading, dated, marked
  `(decided with owner, YYYY-MM-DD)` when the choice was the owner's.
- Concerns **two or more** → its own note (wherever created; the location doesn't matter),
  `type: decision`, `state: done`, tagged `#agent/decision`, linking each note it decided.

**Single source.** Memory never holds a second authoritative copy of a fact that belongs in
a note; a one-line dated echo beside the link is fine, but the note wins on disagreement.

## Links: memory names notes, never the reverse

`[[…]]` inside `.agent-memory/**` always means a note in the visible corpus, folder-qualified
from the vault root, `.md` omitted (`[[ideas/Cross-repo skills registry]]`) — never a memory
file (use a plain relative path for those: `areas/foo/memory.md`). Frontmatter links are
quoted: `covers: ["[[ideas/X]]"]`. Never link from a visible note into a hidden path in any
syntax — it renders dead and is destructive if clicked; publish instead. After the pull the
write cycle already requires, check
`git diff --name-status -M <last-seen>..HEAD -- ':!.agent-memory'` and repair any renamed
targets in one pass; a link that still won't resolve is a Watch Item, never a silent drop.

**Area memory file shape.** Frontmatter: `type: area-memory`, `area:`, `covers:` (quoted
links to the notes this area tracks plus the tags it owns), routing keys, `updated:`,
`tags:`. Body, fixed headings in order: `Status`, `Key Facts`, `Key Deadlines`, `Open
Tasks`, `Watch Items`, `Contacts`, `Published` (what this area promoted, so nobody
re-decides it), `Superseded`, `Completed / Done`, `Source Notes`.

## Writing: targeted edits, no silent forgetting

Smallest matching edit — one line, bullet, or row — never a section or whole-file rewrite;
bump `updated:` on every edit. `concurrency.mdc` governs the git mechanics of writing any
vault file, including these. An aging fact moves to Watch Items, not to nowhere, and stays
until reconfirmed or superseded — never delete an open deadline, task, or active contact to
make room.

## Promotion, procedure vs. facts, session end

Before moving a fact to `GLOBAL.md` because it spans two areas, check whether it should have
been a note instead — a person, deadline, decision or finding two areas depend on is a note
both link, not a global row; `GLOBAL.md` is for what fails the publication test above:
standing agent preferences and cross-area bookkeeping. An area rule (`agent-authoring.mdc`)
states what to do; a memory file states what is true — a recurring fact belongs in memory,
never folded into a rule as an example. Before a session closes, distill anything durable
it produced from the session log into the right area file (reconciled per above) or publish
it — an unread episodic log is a discard, not memory.

## Governance

Ordinary reads and writes under `.agent-memory/**` need no ratification. Changing this rule
follows the vault's baseline governance — an agent proposes via a `#agent/proposal`-tagged
note, the owner ratifies.

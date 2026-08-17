---
name: enrich
description: >-
  Complete a note's floor-schema frontmatter in place, search the corpus and link related
  notes both ways, and append a dated Decisions entry if it's already resolved - as
  bookkeeping this never involves moving the note. Use when the user invokes /enrich, or
  automatically at the start of any vault session before ranking/deciding over the corpus,
  per idea-notes.mdc's enrichment obligation.
---

# enrich - complete a note's floor schema in place

GTD's capture-clarify step, done as bookkeeping in place: enrichment itself never moves or
renames a note, whatever folder it happens to sit in. Run once per note; never batch several
at once, since each needs its own read and its own decision.

## Per note

1. **Read it.** Decide what it is: an idea note (do the steps below), a corpus-spanning
   decision record (`type: decision`, `#agent/decision` - leave it exactly where it is), or
   litter (a stray message, an accidental capture). Litter is read, then deleted; nothing
   else touches it.

2. **Complete the floor schema.** `title` and `state` are required; add `horizon`, `area`,
   `projects`, `domains` where the note's content actually warrants them - don't invent
   values it doesn't support.

3. **Search the corpus, vault-wide** (not folder-scoped - folders carry no meaning here) for
   related notes by title and `domains:` overlap. This is the connect step `idea-notes.mdc`
   requires, not optional polish.

4. **Link both ways.** For each genuine relation found, add a `[[wikilink]]` on this note
   and add the reciprocal `[[wikilink]]` on the other note (a targeted edit to that file,
   not a rewrite), plus any shared `domains:` value both notes should carry. If nothing is
   genuinely related, say so explicitly in the note body ("no genuine relation found")
   rather than leaving the omission silent.

5. **If the note is already resolved** - a closed idea, a dead end - set `state: done` or
   `state: dropped` and append the dated `## Decisions` entry `idea-notes.mdc` requires. Do
   this **in place**, as bookkeeping; "archived" means the state field, not a location. Do
   not move or rename the note as part of enrichment - that's a separate, deliberate act
   (see `idea-notes.mdc`), only when the user asks for or clearly implies it.

6. **One commit per enriched note, pushed immediately** - `concurrency.mdc`'s write cycle,
   not a batch. A rejected push means another agent enriched that note first: `git fetch`,
   confirm, and move to the next note rather than resolving a conflict.

## Automatic vs. manual

`idea-notes.mdc`'s enrichment obligation runs this automatically, for every note
`validate-notes.py --enrich-list` reports, at the start of any vault session that is about
to rank or decide over the corpus. `/enrich` is the same operation invoked on demand - after
a bulk import, or to re-run the connect step on one specific note - and is never required to
make enrichment happen; the obligation already does.

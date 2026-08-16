---
name: triage
description: >-
  Clarify raw captures in inbox/ into triaged ideas, archived closed items, or deleted
  litter - completing the floor schema, searching the corpus for related notes, and
  linking both ways. Use when the user invokes /triage, or when /next finds inbox/
  non-empty and offers it before ranking.
---

# triage - clarify inbox/ into the corpus

GTD's capture->clarify step. Run once per inbox note; never batch-edit several at once,
since each needs its own read and its own decision.

## Per note

1. **Read it.** Decide what it is: an idea (do the steps below), a corpus-spanning
   decision record (`type: decision`, `#agent/decision` - leave it in `inbox/` for the
   owner per `idea-notes.mdc`'s decision-record section, do not move it to `ideas/`), or
   non-idea litter (a stray message, an accidental note) - see `inbox/README.md`'s
   boundary. Litter is read, then deleted; nothing else touches it.

2. **Complete the floor schema.** `title` and `state` are already required; add
   `horizon`, `area`, `projects`, `domains` where the note's content actually warrants
   them - don't invent values it doesn't support.

3. **Search the corpus for related ideas.** Grep `ideas/**` and `archive/**` titles and
   `domains:` values against this note's topic. This is the connect step `idea-notes.mdc`
   requires for every triage, not optional polish.

4. **Link both ways.** For each genuine relation found, add a `[[wikilink]]` on this note
   and add the reciprocal `[[wikilink]]` on the other note (a targeted edit to that file,
   not a rewrite), plus any shared `domains:` value both notes should carry. If nothing
   is genuinely related, say so explicitly in the note body ("no genuine relation found")
   rather than leaving the omission silent.

5. **Decide the destination:**
   - **Real, open idea** -> move to `ideas/`.
   - **Already done or a dead end** -> set `state: done` or `state: dropped`, append the
     dated `## Decisions` entry `idea-notes.mdc` requires, move to `archive/`.
   - **Litter, not an idea** -> delete (step 1 already covers this; don't move it anywhere).

6. **One commit per triaged note.** Small, reviewable, and a partial triage pass never
   leaves a half-edited note staged alongside untouched ones.

## Offered by /next

`/next` (in the consuming factory repo) checks whether `inbox/` is non-empty and offers
this skill before ranking, since untriaged captures have no `projects`/`domains` and are
invisible to a scoped `/next`. The owner gives the soft go per the constitution - nothing
in `inbox/` files itself silently.

# Agent memory

Bookkeeping only - governed by `agent-memory.mdc` and, for the git mechanics of writing any
of it, `concurrency.mdc`. Knowledge worth keeping (a decision, a finding, a deadline, a dead
end) is *published* into the visible corpus rather than stored here; see "Publishing to the
corpus" in `agent-memory.mdc` for the test.

- `INDEX.md` - the mandatory cold-start read: a routing table from routing keys (a path
  glob where the vault has a taxonomy, otherwise `projects:`/`domains:` values and topic
  words) to area memory files. Small forever, and derivable from the area files' own
  frontmatter if it drifts.
- `areas/<slug>/memory.md` - curated durable memory per topic: status, key facts +
  deadlines (each a bi-temporal fact line: slot, value, valid date, confirmed date,
  source/session link), open tasks, watch items, contacts, what's been published to the
  corpus, superseded facts, completed history. In-place edited, smallest targeted edits
  only, reconciled against the same slot before every write.
- `GLOBAL.md` - facts spanning two or more areas that still fail the publication test.
- `sessions/YYYY-MM-DD-<slug>.md` - append-only episodic logs, one file per session, never
  read by default, never edited by another session. Distilled into an area file or
  published at session end.

This dotfolder is invisible to Obsidian and ignored by Obsidian Sync - git is its only
transport. Push after writing; an unpushed memory dies with the container.

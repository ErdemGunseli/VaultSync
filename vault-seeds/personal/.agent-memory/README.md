# Agent memory

Two layers, both governed by the agent-memory rule (.claude/rules/agent-memory.md):

- `INDEX.md` - the mandatory cold-start read: a routing table from scope globs to
  area memory files. Small forever.
- `areas/<slug>/memory.md` - curated durable memory per topic (the generalized Penn
  pattern): status, key facts + deadlines (each with source and as-of date), open
  tasks, watch items, contacts, completed history. In-place edited, smallest
  targeted edits only.
- `GLOBAL.md` - facts spanning two or more areas.
- `sessions/YYYY-MM-DD-<slug>.md` - append-only episodic logs, one file per session,
  never read by default, never edited by another session.

This dotfolder is invisible to Obsidian and ignored by Obsidian Sync - git is its
only transport. Push after writing; an unpushed memory dies with the container.

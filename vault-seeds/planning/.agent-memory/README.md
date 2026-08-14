# .agent-memory/

Append-only session log for agents working this vault. Not corpus content, not a place to
edit ideas from - a running record of what an agent did and why, for the next agent (or the
same one, later) to pick up context without re-deriving it.

## Rules

- **One file per session**, named `YYYY-MM-DD-<session>.md` (`<session>` is a short slug -
  a task name or the orchestrating session's own id). Never append to a previous day's file;
  start a new one.
- **Append-only within a file.** A session writes to its own file as it goes; it does not
  rewrite or delete another session's entry.
- **Written by the memory utility only**, never edited by hand and never edited by an agent
  outside the normal write path. If you are an agent reading this and considering a manual
  edit to a past entry - don't; write a new entry instead.
- **Invisible to Obsidian.** This is a dotfolder, so Obsidian's file explorer and search
  never surface it - it is machinery, not a note in the corpus. Keep it that way; do not
  move memory files into a visible folder.
- **Carried by git, not by Obsidian Sync.** Sync does not traverse dotfolders (see
  `../.claude/rules/vault-constitution.md`), so this history reaches other devices only
  through the same git path everything else in this vault uses.

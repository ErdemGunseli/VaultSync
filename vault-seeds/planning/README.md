# Planning vault

The shared, agent-orchestrated idea corpus. Git is the source of truth; Obsidian (via
VaultSync) is how you and agents read and edit it comfortably. You never browse the raw file
tree day-to-day - you live in `Dashboard/` once it's built.

## Layout

```
inbox/           Raw captures (GTD). One idea per note. Triage from here.
ideas/           The corpus. One note per idea; body scales with importance.
archive/         Completed / dropped ideas (kept, not deleted).
Dashboard/       Where you'll live once a plugin stack is chosen (deferred - see Dashboard/README.md).
_templates/      Note templates (the floor schema).
.agent-memory/   Append-only per-session agent log. Dotfolder - invisible to Obsidian.
.claude/rules/   Agent conventions for this vault (Claude Code).
.cursor/rules/   Same conventions, mirrored for Cursor.
```

## The floor schema

Every idea note requires only `title` and `state`. No numeric priority field, ever -
priority is computed live from context, not stored. See `_templates/idea.md` for the full
shape and `.claude/rules/idea-notes.md` for the conventions agents follow when writing here.

## Governance: agents propose, the owner ratifies

Agents read and write notes freely in `inbox/` and `ideas/`. Changing how the vault itself
works - the rules in `.claude/rules/` or `.cursor/rules/` - is different: an agent proposes a
change as an ordinary note in `inbox/`, and the owner reviews and makes the actual edit (or
explicitly authorizes the agent to). Rules only take effect once committed to git; an edit
made only through Obsidian Sync never reaches another device or agent, because Sync does not
traverse dotfolders. See `.claude/rules/vault-constitution.md` for the full statement.

## Sync

This vault reaches your phone, laptop, and any agent through [VaultSync](../../README.md if
vendored, or the VaultSync repo): a daemon keeps Obsidian Sync and this git repo mirrored in
both directions, so an edit from any device is a commit within moments and a commit from any
agent shows up on every device. See the VaultSync repo's own README and `docs/isolation.md`
for how it works and why agent sessions should open this vault alone, never alongside a
product repo.

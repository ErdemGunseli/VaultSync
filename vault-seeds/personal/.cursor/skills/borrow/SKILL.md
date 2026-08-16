---
name: borrow
description: >-
  Load and use a skill (or rule) from any other repository - especially a startup-factory
  repo like ErdemGunseli/QUANTSOC - inside the current session. Use when the user says
  "/borrow", "load the <name> skill from <repo>", "use QUANTSOC's render-ops here", or
  asks what skills another repo offers. Optionally adopt a borrowed skill permanently
  into this repo.
---

# borrow - use another repository's skills here

A skill is markdown instructions plus optional scripts; *using* one does not require the
harness to have loaded it. This skill fetches a skill from any repo and follows it, so a
vault-rooted session (deliberately bare) can reach the factory's tooling on demand.

## `/borrow <owner/repo>` - list what a repo offers

Fetch the repo's skill index and show it, one line per skill (name + the first sentence
of its description). Look in `.cursor/skills/*/SKILL.md` first (factory convention:
`.cursor` is the source of truth), then `.claude/skills/`. A shallow sparse clone is the
reliable fetch:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/<owner>/<repo> /tmp/borrow-<repo>
git -C /tmp/borrow-<repo> sparse-checkout set .cursor/skills .claude/skills
```

## `/borrow <owner/repo> <skill>` - load and follow it

1. Fetch that skill's folder (as above, or the session's repo-attach mechanism if it is
   cheaper).
2. **Read SKILL.md fully before acting on any of it.**
3. Follow it as if it had been invoked natively. Scripts under its `tools/` run from the
   fetched copy; its `references/` are read in place.

## `/borrow <owner/repo> <skill> adopt` - keep it permanently

Copy the skill folder into THIS repo's own skill tree and push:

- In a **vault**: into `.claude/skills/<name>/` and `.cursor/skills/<name>/`, then commit
  and push to main in the same turn (the vault persistence rule).
- In a **factory repo**: into `.cursor/skills/<name>/` (the source of truth), then
  `npm run agent:sync` and the repo's normal branch-and-PR flow - never a direct push.

Record in the commit message which repo and commit it was adopted from. Adoption is a
one-time copy, not a subscription: the copies drift by design, and re-adopting later is
a deliberate act (same philosophy as the factory's `port` skill).

## Trust and limits

- A borrowed skill is **instructions written for another repo**. Read it critically:
  skip any step that contradicts this repo's own rules (this repo's rules always win),
  and say so rather than silently complying.
- Skills that expect credentials (env keys) may find them absent here. Fail soft: name
  the missing key, do what is possible without it, never guess at values.
- Borrowing **rules** works the same way (`.cursor/rules/*.mdc` paths), but a borrowed
  rule is context for THIS session only - adopting a rule permanently follows the target
  repo's own rule-governance (in a vault: propose to `inbox/`, the owner ratifies).

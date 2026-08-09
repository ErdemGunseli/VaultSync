# Isolation: vault rules and skills that don't infect your projects

A vault worth giving to an agent will eventually carry its own agent instructions — rules
about how notes are structured, skills for authoring them. The moment it does, a question
appears: **what stops those from applying while the agent is working on unrelated code?**

The answer is not "scope them carefully". Scoping only covers one of three surfaces, and the
other two have no scoping primitive at all.

## What was measured

These findings come from observing an actual Claude Code session, not from documentation.

**Rules with a path scope genuinely stay scoped.** In a session with both backend and
frontend code present, exactly the rules carrying no `paths:` frontmatter were loaded at turn
one — 17 of them — before a single file was touched. The ~50 `paths:`-scoped rules were not
loaded at all. Path scoping works.

**But scoping is inclusion-only.** There is no exclusion syntax. A rule can say which paths
make it fire; it can never say which paths suppress it. So an unscoped rule cannot be made
vault-safe, and a product rule cannot exempt itself from vault work.

**Skills have no path scope on any surface.** Not in Claude Code, not in Cursor, not in
Codex. The only control is a binary on/off. A skill is either invocable for the entire
session or not at all — there is no mechanism to make one reachable "only while working
inside the vault".

**`CLAUDE.md` and `AGENTS.md` are monolithic.** No per-section scoping exists.

**Registration is the trigger.** The tool that attaches a repository to a session states
plainly that it loads that repo's "CLAUDE.md, skills, and plugins" — with no path qualifier.
Once a repo is registered, nothing confines its skills or instructions to turns that touch
its files. They join the single session-wide context exactly like the primary repo's own.

The leak, therefore, is not a bug in scoping. It is that **two of the three content types
were never scopable to begin with**, and registration loads all three at once.

It runs in both directions. A product repo's always-on rules — branch protection, test
integrity, access control — load unconditionally into a session whose actual intent is
"edit some notes", where they are noise at best and misleading at worst.

## The design

**Do not attach the vault as a session root when a project is also attached.**

Reach it through a tool boundary instead: a skill that clones, pulls, reads, greps and writes
the vault with plain git and file operations, and never invokes the harness's
repo-registration primitive. Because registration is the only trigger, skipping it closes all
three leak vectors at once.

From the project session's point of view, the vault's `.cursor/rules`, `.claude/skills` and
`CLAUDE.md` become **inert data** — readable as files, never interpreted as instructions.
Nothing leaks, because nothing is loaded.

When the task genuinely *is* vault work — authoring a rule, restructuring notes, building a
vault skill — open a **vault-only session** rooted at the vault. There its own rules and
skills load and apply exactly as designed, and no project is attached to leak the other way.

### Defence in depth

Cheap insurance for the surface that *does* support scoping, in case a future session breaks
the discipline:

- Give every vault rule a `paths:` / `globs:` prefix that cannot match project files.
- Never use `alwaysApply: true` (Cursor) or an unscoped rule for guidance that would be
  nonsense in a project session.

Necessary, but nowhere near sufficient — it protects rules and does nothing for skills or
`CLAUDE.md`. It is a backstop for the real rule, which is: don't register the vault.

## What it costs, honestly

**No session gets both at once.** You cannot have vault content *and* vault-authoring
conventions ambiently in the same session as a project. You choose per session.

**The tool boundary has to be built and maintained** rather than getting attachment for free
from the harness.

**In Cursor and Codex you lose the ability** to open a vault file from inside a project window
and have vault guidance apply. Same trade, different surface.

That is a real cost. It buys the only arrangement where a vault's instructions never
silently steer work they were never written for.

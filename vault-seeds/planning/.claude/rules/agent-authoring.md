---
alwaysApply: false
paths: ideas/**,inbox/**,archive/**,Dashboard/**,_templates/**,.agent-memory/**
---

# Agent authoring: rules, skills, workflows, and note formats

Agents do not merely follow this vault's conventions - they build them. When a workflow
recurs, an agent is expected to notice and codify it, the way the Penn admin process was
codified, rather than re-deriving it every session.

## What an agent may create directly (push to main, announce in chat)

- **Area rules** - a path-scoped rule capturing an area's process or memory discipline
  (the generalized Penn pattern: what to read first, what to update, what never to do).
- **Note-format standards** - agents generate most user-facing notes here, so agents own
  the formatting contracts: for each note-producing area, a path-scoped rule stating
  frontmatter schema, `type:`, section headings in order, image/link conventions, and
  tone. Match the existing area's dominant pattern before inventing one; a new format is
  a deliberate act, recorded in the rule, never an accident of one session's taste.
- **Skills** - a workflow worth invoking by name becomes a skill in `.claude/skills/` +
  `.cursor/skills/` (both mirrors, identical), written to the same standard as the
  factory's: frontmatter with name + trigger description, concise imperative body.
- **Area memory files** under `.agent-memory/` per the agent-memory rule.

Announce every created or materially changed rule/skill/standard in the chat response of
the turn that pushed it - creation is visible, never silent.

## What still needs the owner's ratification

The **baseline** - the constitution, the persistence rule, the agent-memory rule, this
rule, and anything governing sync, secrets, or access. Propose changes to those as a note
in `inbox/` and stop; the owner ratifies. The line: agents extend the system freely,
but do not amend its foundations on their own.

## Quality bar

A rule an agent writes binds every future agent, so it is held to the factory's standard:
state the dominant evidenced pattern, never launder one session's inconsistency into
house style; scope with directory-prefixed globs (a bare leading `*` is invalid YAML and
a silent no-load); keep it as short as the obligation allows; and when a rule's subject
changes, the same turn updates the rule - a stale rule is worse than none.

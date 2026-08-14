---
alwaysApply: false
paths: ideas/**/*.md,inbox/**/*.md,archive/**/*.md,Dashboard/**/*.md,_templates/**/*.md
---

<!--
paths is vault-relative and deliberately directory-prefixed: a bare **/*.md is
invalid YAML (leading * scans as an alias) and would also match ANY markdown in a
cross-root session, which is unverified territory - see docs/isolation.md in the
VaultSync repo. Directory-prefixed globs are the same convention the QUANTSOC rule
corpus uses. This vault should still be opened as its own session root, never
registered alongside a product repo.
-->

# Vault constitution

This vault is the source of truth for the planning corpus. Everything here follows from
that.

## Rules change only via git

The rules in `.claude/rules/` and `.cursor/rules/` govern how agents write into this vault.
They change by editing the file and committing - never by an in-app edit that only reaches
Obsidian Sync. Sync does not traverse dotfolders, so a change made only through Sync would
never leave this device: git is not a preference here, it is the only path a rule change can
actually take to reach another device or another agent. That is the enforcement, not a
convention layered on top of it.

## Agents propose, the owner ratifies

An agent that wants a rule changed writes an ordinary note into `inbox/` describing the
proposed change and why. It does not edit `.claude/rules/` or `.cursor/rules/` directly. The
vault owner reviews the proposal and, if they agree, makes the edit and commits it
themselves (or explicitly authorizes the agent to). No rule in this vault self-amends.

## The 5 MB per-file sync cap is a hard rule

Any file over 5 MB breaks the Obsidian Sync <-> git bridge for this vault. Keep large binary
attachments (video, high-resolution images, PDFs, archives) out of files that exceed the
cap, and route them through LFS (see `.gitattributes`) rather than committing them raw. This
is not a style preference - a file over the cap desyncs the vault until someone manually
intervenes.

## Conflicts are surfaced, never auto-resolved

If a sync conflict produces a `*.sync-conflict-*.md` or `*conflicted copy*.md` file, it is
left in place for a human to resolve - see `.gitignore`, which keeps these out of git history
on purpose (they are transport-layer output, not authored content) while still surfacing
them in the working tree. No agent auto-merges, auto-deletes, or auto-picks-a-winner between
conflicting copies. Flag it and stop.

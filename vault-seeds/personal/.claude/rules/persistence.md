---
paths: Notes/**/*.md
---

# Persistence: main is the delivery surface

This vault is mirrored to the owner's devices by Obsidian Sync through the VaultSync
daemon (github.com/ErdemGunseli/VaultSync), and the daemon watches ONLY `main`.
A change that is not pushed to `main` does not exist: it never reaches a phone, and
the session's container is reclaimed with it.

- **Default execution path: make the change, answer in chat, and COMMIT AND PUSH TO
  `main` in the same turn** - not at session end. "Deliverable beyond the session" is
  the default assumption for every change in a vault; treat an unpushed edit as work
  not yet done.
- **No PR flow and no feature branches here.** A vault is notes, not code. The daemon
  merges the way Obsidian Sync merges; a genuine collision surfaces as a
  "(conflicted copy ...)" note on the owner's devices, never as lost data - git
  history keeps every side.
- **Pull before writing, push after.** A fresh pull avoids needless conflicted copies.

SCOPE: this rule governs THE VAULT REPO ONLY. It never applies to any software
repository attached to the same session - those repos' own branch-protection and PR
rules stand unchanged, and "push to main immediately" must never leak onto them.

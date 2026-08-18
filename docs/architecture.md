# Architecture

## Components

**The daemon** (`daemon/`) is the only always-on member of the Obsidian Sync mesh that also
speaks git. It holds the Sync connection open, and on each reconcile pass (event-driven within ~1-2s of a local edit, plus an adaptive remote poll) pulls `--ff-only` and
commits-and-pushes whatever is dirty. It is the *entire* reason phone-to-git works.

**The agent skill** is built and cold-start verified: it lives in the consuming repo (the
`vault` skill in the startup factory), not here, and gives agents a checkout plus the
vault's own rules read as data. See [`agent-access.md`](agent-access.md).

**The vault content** lives in a **separate, private** repository. This repo is machinery;
your notes are data. Keeping them apart means the machinery can be public, versioned and
shared without ever touching what is in your notes.

These two halves solve **non-overlapping** problems. Agents talking to git directly does
nothing for phone-to-git; the daemon does nothing for an agent's ability to grep. Neither
replaces the other.

## Why one repo for the machinery

The daemon and the skill share one design contract — what a conflict means, what fails soft,
what must never be rewritten. That contract is cheaper to keep coherent in one place than
across two repos that drift.

The one thing needing genuine isolation is the daemon's independent deploy lifecycle, and
that is satisfied by this being its own repo rather than living inside a larger project. No
further splitting earns its keep.

## Latency and consistency

Each direction is bounded by the adaptive remote poll (VAULT_POLL_ACTIVE 2s while active, backing off to VAULT_POLL_IDLE 30s when idle) plus Sync propagation — under a
minute in practice, both ways.

The real hazard is not latency but **staleness inside a long session**: an agent's checkout
is refreshed when the session starts, and then not again. It can reason over stale notes for
a long time without being told. Any skill built here must re-check freshness before a write,
and should surface the checkout's age on request rather than implying currency it doesn't
have.

## Conflicts

The daemon's behaviour is fully specified: pull `--ff-only`, never force-push, log every
divergence and every Sync conflict file, and leave both for a human.

**The agent side is specified now.** An agent that finds a conflicted vault stops and
reports: the `vault` skill's safety rails make a conflicted copy the owner's to reconcile,
and the vault's own concurrency rule says the same. Never resolve one on the agent's own
initiative.

## Failure modes that are silent by design

Worth knowing, because none of them will page you:

- An unconfigured daemon idles quietly. There is no health endpoint, because there is no
  inbound surface to serve one on.
- Expired Obsidian auth degrades to git-only. Agents keep working; phone edits stop arriving.
  The log says so; nothing else does.
- A push that fails retries forever. If it is failing because an LFS quota is exhausted, that
  loop never clears on its own.

## What would make this design wrong

Stated plainly, so it can be checked rather than assumed:

- **Obsidian ships a webhook or server-side API.** The daemon's entire justification
  evaporates and this project should be deleted.
- **The mobile Obsidian Git plugin becomes genuinely reliable** *and* gains background
  execution. The second half matters more than the first — without it, a foreground plugin
  still cannot sync while no client is open.
- **The skill grows far past "a checkout plus a small CLI".** If it does, the one-repo
  argument weakens and the two halves should separate.
- **Sub-second cross-agent consistency turns out to be a real requirement.** Then the
  stateless-reparse design is insufficient and a shared service becomes justified.

## An ambiguity worth naming

"Agent access with Obsidian's connection logic" can mean two very different things:

1. **Agents get git access to the vault** and a parser that understands Obsidian's link
   syntax. Low risk, mostly built.
2. **Agents join the Obsidian Sync mesh themselves**, running `ob` per session.

This repo assumes (1). Option (2) multiplies Sync membership across ephemeral sessions,
consumes device slots against the account's plan limits, and directly contradicts "the daemon
is the only always-on member". It should not be adopted without a specific reason that (1)
cannot serve.

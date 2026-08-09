# Agent access: how an agent reads a vault

## The shape

A local git checkout, the agent's own native file tools, and one small CLI for the link
graph. That is the whole design.

An Obsidian vault is a directory of markdown. An agent's existing Read / Glob / Grep already
give full-text search, path globbing and arbitrary reads over it — the same capabilities it
has on any code repository, at zero additional latency and with no new failure surface. **Do
not rebuild what native tools already do.**

## What native tools genuinely cannot do

One thing: the **link graph**. Relationships live inside note text as `[[wikilinks]]`, and
grep cannot follow them. Specifically, grep cannot:

- answer "what links *to* this note" without an inverted index,
- resolve an alias or a shortened link to its canonical target,
- walk multiple hops without stitching many searches together.

So the CLI covers exactly that: backlinks, forward links, alias resolution, and depth-capped
traversal.

## What is deliberately out of scope

This was originally framed as "the link graph is the *only* gap". That framing did not
survive scrutiny, and the honest version is a scope decision rather than a completeness
claim. **Not covered**, and not planned without a real need:

- **Dataview / Bases queries** — an execution engine, not a graph.
- **Unlinked mentions** — fuzzy title matching, a third mechanism distinct from both link
  syntax and traversal.
- **Block-reference and transclusion resolution** — anchor resolution rather than
  edge existence.
- **Canvas files** — JSON, not markdown.
- **Structured frontmatter queries at scale** — grep handles the simple cases.

An agent asking for any of these gets an explicit "not supported", never a wrong answer.

## Freshness: no cache

The obvious design is to build a link index, stamp it with the checkout's commit hash, and
rebuild when they differ. **That design is broken**, and measurement is what killed it.

The stamp never changes for **uncommitted** edits — which is the dominant case, because an
agent edits a note and immediately asks about it. HEAD hasn't moved, so a stale index is
served as though it were fresh. Wrong-but-plausible backlinks are worse than no backlinks.

The fix is to not cache. On a synthetic **20,000-note** vault (~79 MB, 81,416 links — four
times the expected size), a full parse takes **0.41 s**, `grep -r` takes 0.17 s and `rg` takes
0.06 s. Reparsing on every query is cheap enough that the entire staleness problem, and the
invalidation logic that would have managed it, simply does not need to exist.

## Why not an MCP server

Not on principle — on merit for this case.

The one place a persistent server would earn its keep is live freshness via file watching, and
the measurements above dissolve that need: a sub-second reparse is simpler and always correct.
What remains is a server that duplicates native file tools for content access, adds a process
to keep alive, and introduces a state-drift bug class a stateless script cannot have (server
started against one commit, checkout now at another).

MCP is the right tool when a resource has no filesystem representation — a live API, a
database. A git-backed vault *is* a filesystem, so the premise doesn't hold.

If graph queries ever need to be shared live across many concurrent agents with sub-second
staleness tolerance, that is a genuine server-shaped requirement. It should be built when it
is demonstrated, not before.

## Why not the GitHub API alone

No Glob or Grep equivalent exists remotely without re-downloading content per query. Every
read becomes a network round trip and every search becomes either code-search (with indexing
lag and mismatched semantics) or fetching the whole tree — materially slower and costlier,
and rate-limited at vault scale.

It stays as a documented fallback for a stateless agent with no disk, never the default.

## What the skill hides, and what it must not

**Hidden:** clone existence and location, pull freshness, authentication. One entry point
handles them before the agent touches a file.

**Surfaced, never swallowed:**

- **Merge conflicts.** Silently picking a side in someone's personal notes is a correctness
  risk. The skill reports "conflicted, cannot answer" as a real outcome.
- **LFS attachments.** Not fetched by default, with an explicit opt-in. Silent download costs
  bandwidth; silent absence leaves an agent unable to explain a failed read.

## Known risk

Index correctness depends entirely on the link parser. A parser that misses an alias form or
a resolution rule produces an index that is **confidently wrong rather than obviously
absent** — the most expensive failure mode available. See
[`obsidian-link-semantics.md`](obsidian-link-semantics.md) for the specification, including
the five behaviours that need empirical testing against a real vault before they are trusted.

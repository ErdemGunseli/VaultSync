# Obsidian link and connection semantics

The specification a parser must implement for an agent's view of "what connects to what" to
match what a human sees in Obsidian.

Sourced from the official documentation source repository (`obsidianmd/obsidian-help`) and
the official plugin API type definitions (`obsidianmd/obsidian-api`, `obsidian.d.ts`) rather
than the rendered help site, several pages of which 404 through redirects.

**Read the "verified vs assumed" split at the end before trusting any of this in code.**
Five behaviours are undocumented and need empirical testing against a real vault - a parser
that guesses at them produces an index that is confidently wrong rather than obviously
absent.

---

## 1. Link syntax and meaning

**Note link (wikilink):** `[[Note name]]` or `[[Note name.md]]` — both work,
`.md` optional for markdown files. Equivalent markdown-link form:
`[Note name](Note%20name.md)` (destination must be URL-encoded — spaces →
`%20`). Both forms are semantically identical and render identically.
Source: `Linking notes and files/Internal links.md`.

**Alias/display text:** `[[Note|Custom name]]` or markdown
`[Custom name](Note.md)`. This is a *per-occurrence* display override, distinct
from a note's `aliases` frontmatter property (§3). Same doc, "Change the link
display text".

**Heading link:** `[[Note#Heading]]`; same-note form `[[#Heading]]`; nested
heading form uses repeated `#`: `[[Note#H1#H2]]` (NOT `#H1##H2` or `/` — literally
chained `#`). Vault-wide heading search uses `[[## heading text]]` syntax in the
UI (double `#`).

**Block link:** `[[Note#^blockid]]`. Block IDs are user-visible tokens matching
`^[a-zA-Z0-9-]+` (Latin letters, numbers, dashes only) placed at the end of a
paragraph/line. For structured blocks (lists, quotes, callouts, tables) the
`^id` must be on its own line with a blank line before and after. **Obsidian
explicitly does not support linking to a specific row/cell inside a table or
callout/quote sub-part** — only to the whole block. Auto-generated block IDs
(when you type `^` and pick a suggestion) are short hashes like `^37066d`;
hand-authored ones can be human-readable (`^quote-of-the-day`). Vault-wide block
search UI syntax: `[[^^block text]]`.
Block references are **Obsidian-specific, not standard Markdown** — they will
not resolve in other tools.

**Embed / transclusion:** prefix any of the above with `!`: `![[Note]]`,
`![[Note#Heading]]`, `![[Note#^block]]`. "Embedded files display their content
inline in a note and stay up to date when the source file changes" — i.e. it is
a live transclusion, not a copy. Embeds apply to any accepted file type:
notes (whole note, a heading's section, or a block/list), images (`![[img.jpg]]`,
with `|WxH` or `|W` sizing suffix), audio, PDF (`![[doc.pdf#page=N]]`,
`#height=N`), and `.canvas` files (embeds shapes only, not in-card text —
a documented gap). A **link is a reference that navigates**; an **embed is a
link that also renders the target's content inline**. "Transclusion" =
Obsidian's/general term for the embed rendering behaviour.
Source: `Linking notes and files/Embed files.md`, `Internal links.md`.

**Invalid characters in link targets:** `# | ^ : %% [[ ]]` may break a link if
present in a filename — Obsidian's own recommendation is to avoid them in
filenames.

---

## 2. Link resolution

**Folder-qualified links** (`[[Projects/Note]]`) resolve straightforwardly:
vault-root-relative path, forward slashes even on Windows. If the target
doesn't exist, Obsidian **creates the note at that path** (ignoring the "default
location for new notes" setting) — relevant for an agent that must decide
whether an unresolved link is "broken" or "would auto-create here."

**Bare-name links** (`[[Note]]`, no folder) resolve by **shortest-unique-path
matching across the whole vault**, independent of where the linking note lives.
This is NOT documented as an explicit algorithm in the help docs (verified: the
help pages describe the *outbound* setting "New link format" — what Obsidian
*writes* when auto-generating a link — but do not fully spec the *resolution*
algorithm for an arbitrary typed/imported link). What is confirmed from the
official plugin API (`obsidian.d.ts`):
- `MetadataCache.getFirstLinkpathDest(linkpath, sourcePath): TFile | null` is
  the canonical resolver — "gets the best match for a linkpath." It takes the
  *source* file's path as context (so relative resolution against the source
  folder is possible) but the exact precedence order (relative-to-source vault
  first vs. global shortest-path first) is **not spelled out in either the
  help docs or the `.d.ts` comments** — ASSUMED/UNVERIFIED, would need
  empirical testing.
- The inverse, `MetadataCache.fileToLinktext(file, sourcePath, omitMdExtension)`,
  is documented precisely: **"If file name is unique, use the filename. If not
  unique, use full path."** This is the authoritative statement of Obsidian's
  own duplicate-basename policy for names it generates, and strongly implies
  the same shortest-unique-path logic governs resolution symmetrically.

**"New link format" setting** (Settings → Files and links → Links → New link
format) controls only what Obsidian *writes* for newly auto-generated links,
not how it *resolves* existing ones. Three options: **Shortest path when
possible** (default; unique filename if possible, else full path — matches
`fileToLinktext` behaviour above), **Relative path to file** (path relative to
the linking note), **Absolute path in vault** (full path from vault root).
Source: `User interface/Settings.md` lines ~206-213.

**Duplicate basenames across folders:** confirmed as a known ambiguity in
community reports (Obsidian forum, not official docs): a bare `[[Note]]` link
resolves to *some one* matching file when multiple files share that basename in
different folders, and which one is chosen is not user-controllable except by
qualifying the link with a folder path. Obsidian's own guidance (implicit via
`fileToLinktext`) is: **don't rely on bare names once a basename is
non-unique — use folder-qualified links.** For a faithful reproduction, an
implementer must replicate whatever precedence Obsidian's live resolver uses
(cache order / most-recently-resolved / alphabetical — **not documented**,
empirical-test territory) or, more robustly, treat any bare link matching >1
file as inherently ambiguous and flag it rather than silently guessing.

**Case sensitivity:** Not explicitly stated for link *resolution* in the docs
consulted. Tag matching is explicitly documented as case-insensitive (§4); file
path resolution on case-insensitive filesystems (default macOS/Windows) is
filesystem-level case-insensitive, but on Linux (case-sensitive filesystem,
relevant to a git-vault running in a container) this is genuinely ambiguous
territory — **UNVERIFIED, flag for empirical testing** given VaultSync likely
runs on Linux.

**`.md` extension rule:** For markdown notes, the extension is optional in both
wikilink and markdown-link forms (`[[Note]]` == `[[Note.md]]`). For **non-markdown
files** (images, PDFs, canvases, etc.) the extension is **required**:
"links to file formats other than Markdown needs to include a file extension."
Source: `Internal links.md`.

**Unresolved links:** A link to a note that doesn't exist yet renders "in a more
muted color" (dead-link styling) rather than erroring. Programmatically, the
plugin API exposes this as two parallel maps on `MetadataCache`:
- `resolvedLinks: Record<sourcePath, Record<destPath, count>>` — vault-absolute
  paths usable with `Vault.getAbstractFileByPath`.
- `unresolvedLinks: Record<sourcePath, Record<unresolvedLinktext, count>>` —
  same shape but destination key is the raw unresolved linktext, not a path
  (because there's no file to point at).
Both are populated asynchronously; the API exposes `'resolve'` (per-file) and
`'resolved'` (all-files) events to know when the cache is settled. This
resolved/unresolved split, keyed with per-pair **counts** (not just booleans —
multiple links between the same two files count each occurrence), is the
authoritative shape an implementer should mirror.
Source: `obsidian.d.ts` (`MetadataCache.resolvedLinks` / `.unresolvedLinks`
doc comments, lines ~4435-4444).

**Whether embeds merge into `resolvedLinks`:** The `.d.ts` doc comment for
`resolvedLinks` does not explicitly say whether embed targets (`![[...]]`) are
folded into the same map as regular links, only that `CachedMetadata` itself
keeps `links` (LinkCache[]) and `embeds` (EmbedCache[]) as **separate arrays**
per file (both extend the same `ReferenceCache`/`Reference` shape: `link`,
`original`, optional `displayText`). Whether `resolvedLinks` is `links ∪ embeds`
or `links` only is **ASSUMED (not directly verified)** — treat as a concrete
empirical-test item, since it changes whether an embed alone creates a graph
edge/backlink.

---

## 3. Aliases

Declared via the `aliases` frontmatter property, always a YAML list:
```yaml
aliases:
  - Doggo
  - Woofer
```
Effects, all confirmed in docs:
- Any alias appears in `[[` link-suggestion autocomplete (marked with a curved
  arrow icon) alongside the real filename.
- When you pick an alias from suggestions, Obsidian writes the link as
  `[[RealNoteName|AliasText]]` — i.e. **it resolves to the canonical wikilink
  target and stores the alias only as display text**, specifically "to ensure
  interoperability with other applications using the Wikilink format." So on
  disk/graph level, an alias-based link is indistinguishable from a manual
  `[[Note|Custom name]]` display-text link — there is no separate "linked via
  alias" edge type.
- Aliases participate in **Backlinks' "unlinked mentions"**: plain-text
  occurrences of an alias string elsewhere in the vault surface as unlinked
  mentions of the aliased note, same as occurrences of the real title would.
Source: `Linking notes and files/Aliases.md`.

Deprecated alternate key: `alias` (singular) — deprecated since Obsidian 1.4,
support **dropped in Obsidian 1.9** (so a vault authored pre-1.9 might still
carry it, but current Obsidian will not treat it specially). See §5.

---

## 4. Tags

**Inline tag:** `#keyword` anywhere in note body. **Frontmatter tag:** the
`tags` property, must be a YAML list (`tags:\n  - recipe\n  - cooking`) — a
comma-string form is *not* the documented/supported shape (community reports
say a plain string sometimes half-works with `dataview` but that's a
third-party plugin quirk, not core Obsidian behaviour).

**Nested tags:** `#inbox/to-read` — hierarchy via `/`. A parent-tag search
(`tag:inbox` or `hasTag("a")` in Bases) matches the parent **and all
descendants** (`#inbox/to-read`, `#inbox/processing`, etc.) — this is a
real semantic (tag-prefix matching), not just display grouping.

**Tag character rules (exact, from docs):** letters, numbers, `_`, `-`, `/`
(nesting separator), and "commonly accepted Unicode characters including
emojis." **Must contain at least one non-numerical character** — `#1984` is
invalid (parsed as not-a-tag, e.g. could be a heading anchor / plain text),
`#y1984` is valid. **No spaces** — multi-word tags must be `camelCase`,
`PascalCase`, `snake_case`, or `kebab-case`. **Case-insensitive**: `#tag` and
`#TAG` are the same tag; **displayed with whichever casing was used first** to
create it, vault-wide (a later differently-cased usage does not change display).

**Tag vs heading anchor vs markdown fragment — the actual disambiguation an
implementer needs:** a bare `#word` in body text is only a tag if it matches
the tag grammar above (starts right after non-word-boundary, contains a
non-numeric char, no invalid chars). `#` inside `[[Note#Heading]]` is never a
tag — it's the heading-link separator, distinguished purely by being inside a
wikilink/markdown-link's target syntax, not by the `#` character itself. A
markdown URL fragment like `https://example.com/page#section` is not a tag
either — practically this means: **tag scanning must exclude `#` characters
that occur (a) inside `[[...]]` / `[...](...)`  link targets, and (b) inside
URLs**, and must apply the char-class + "≥1 non-numeric char" + "no leading
digit-only" rule to whatever's left. This exact boundary logic is not spelled
out end-to-end in one place in the docs — it's assembled from the tag-format
rules plus the link-syntax rules; **flag as an implementer trap**, worth
empirical testing against Obsidian's own tag highlighting in Live Preview.

Source: `Editing and formatting/Tags.md`.

---

## 5. Frontmatter / properties

YAML block delimited by `---` at file start (JSON also accepted, "read,
interpreted, and saved as YAML"). Format: `name: value`, colon+space,
**names must be unique per note** (can't have two `tags:` blocks).

**Seven property types**, each with real behavioural differences an
implementer must replicate, not just cosmetic:
| Type | Behaviour |
|---|---|
| Text | single line; **Markdown not rendered; `#hashtag`-looking text does NOT create a tag** |
| List | each value own line, `- ` prefix |
| Number | literal only, no expressions |
| Checkbox | `true`/`false`/indeterminate (blank, "often treated as false") |
| Date | `YYYY-MM-DD`; with Daily Notes plugin enabled, **functions as an internal link** to that day's daily note |
| Date & time | `YYYY-MM-DDTHH:MM:SS` |
| Tags | **exclusive to the `tags` property name** — can't assign this type elsewhere |

**Internal links inside text/list properties must be quoted**:
`link: "[[Episode IV]]"` — Obsidian auto-adds the quotes when you enter a link
via its UI, but a hand-written/imported YAML file (exactly VaultSync's git
scenario) that omits the quotes risks the YAML parser treating `[[Episode IV]]`
as a YAML flow-sequence rather than a string containing a wikilink, silently
breaking link detection in that property. **Trap.**

**Properties with special built-in meaning (three, confirmed):** `tags`,
`aliases`, `cssclasses` (styling only, no graph effect). Obsidian-Publish-only
special properties: `publish`, `permalink`, `description`, `image`, `cover` —
these affect a hosted-Publish site, not vault-local graph semantics, but worth
knowing they exist and are reserved.

**Deprecated singular forms** — `tag`, `alias`, `cssclass` — deprecated in
1.4, **special-casing dropped entirely in 1.9**. A vault frontmatter using
these on current Obsidian is just an ordinary custom property, not a tag/alias
source. Implementer must know which Obsidian version's semantics to target
(current vs. 1.4–1.8) since the resolver behaviour genuinely differs.

**Not supported (explicit gaps):** nested/hierarchical properties, bulk editing
in the built-in UI, Markdown rendering inside property values.

Source: `Editing and formatting/Properties.md`.

The API-level shape: `CachedMetadata.frontmatter?: FrontMatterCache`, plus a
separate `frontmatterLinks?: FrontmatterLinkCache[]` array (added 1.4.0) —
confirms Obsidian parses links found *inside* frontmatter as a distinct
tracked category from body `links`/`embeds`, which a faithful graph builder
should mirror (frontmatter-embedded links do participate in backlinks/graph,
per the quoted-wikilink mechanism above, but are cached separately internally).

---

## 6. Backlinks

**Definition (confirmed, official):** "if 'Three laws of motion' contains a
link to 'Isaac Newton', a corresponding backlink appears in the Isaac Newton
note" — i.e. backlinks are the reverse-index of `resolvedLinks`, computed per
target file.

**Linked mentions vs. unlinked mentions** — the Backlinks core plugin's two
sections, both official terms:
- **Linked mentions**: "backlinks to the notes that contain an internal link to
  the active note" — i.e. real `[[...]]`/markdown-link edges, reverse-indexed.
- **Unlinked mentions**: "backlinks to any unlinked occurrence of the name of
  the active note" — **plain-text string matching** of the note's title *or any
  of its aliases* elsewhere in the vault, where no actual link markup exists.
  This is explicitly **not** part of the link graph proper — it's a
  discovery/suggestion feature (each unlinked mention has a UI affordance to
  convert it into a real link). Unlinked-mention scanning **respects the
  vault's Excluded Files patterns** (files matching those patterns are never
  surfaced as unlinked mentions).
- Converting an unlinked mention of an *alias* turns it into a real internal
  link **with the alias as display text** (same `[[Real|Alias]]` shape as §3).

**Does backlinks include embeds?** Not stated explicitly either way in the
Backlinks doc; since embeds are links with a leading `!`, and the doc only
distinguishes "internal link" from "unlinked occurrence," the natural reading
is that embed-links count as linked mentions same as plain links (an embed is
syntactically a link). **Treat as reasonably-confident-but-unverified** —
matches the same ambiguity flagged in §2 about whether `resolvedLinks` folds
in `embeds`.

**Unresolved links and backlinks:** not addressed in the Backlinks doc at all;
by construction (backlinks are the reverse map for resolved edges only — you
can't backlink to a file that doesn't exist / doesn't resolve to a `TFile`),
an unresolved link cannot produce a linked-mention backlink. This is inference
from the `resolvedLinks`/`unresolvedLinks` API split (§2), not an explicit
doc statement.

Source: `en/Editing and formatting/` — actually the Backlinks doc lives at
`obsidian.md/help/plugins/backlinks` (core-plugin docs tree; not fetched into
the local clone's diffed path in this pass, content captured via WebFetch
above — reasonably high confidence, official page, but note it wasn't
cross-checked against the raw repo file the way §1–5 were).

---

## 7. Attachments

Attachments are "regular files... accessible using your file system," embedded
via the same `![[...]]` syntax as any other link target (§1). Default location
setting (Settings → Files & Links → Default location for new attachments), four
modes:
- **Vault folder** — vault root (this is the true default, confirmed twice in
  docs).
- **In the folder specified below** — one fixed folder.
- **Same folder as current file** — colocated with the linking note.
- **In subfolder under current folder** — a named subfolder next to the note;
  **created automatically by Obsidian if it doesn't exist** when an attachment
  is added.
This setting only governs **where Obsidian places newly added attachments**
(paste/drag-drop/download-to-vault) — it does not change how an existing
`![[Figure 1.png]]` reference *resolves*, which follows the same
shortest-unique-path-across-vault rule as any other link target (§2), extension
required. For a git-synced vault (VaultSync's actual substrate) this setting is
mostly moot for *reading* — resolution logic (§2) is what matters — but matters
if VaultSync itself ever creates attachments programmatically and needs to
match where a human's Obsidian client would have put them.
Source: `Editing and formatting/Attachments.md`, `User interface/Settings.md`.

---

## Implementer's checklist

1. Parse three link forms uniformly: wikilink, embed-wikilink (`!` prefix),
   markdown link — normalize to one internal `{target, subtarget: heading|block|none, displayText, isEmbed}` shape.
2. Split `target` into `notePath` + optional `#heading[#subheading...]` or
   `#^blockid`. Handle same-note `[[#Heading]]` (empty notePath = self).
3. Resolve `notePath` against the **whole vault by basename** (case rules TBD,
   test empirically) when it has no folder component; if it has a folder
   component, treat as vault-root-relative. `.md` optional for markdown files,
   required for everything else.
4. On multiple basename matches: pick a deterministic policy and document it
   as a deviation risk (Obsidian's actual tie-break is undocumented).
5. Track resolved vs. unresolved separately, with **counts**, mirroring
   `resolvedLinks`/`unresolvedLinks` — don't collapse multiplicity.
6. Load `aliases` (list) per note; treat as additional resolution targets
   equivalent to the note's own filename (alias → same file, not a separate
   node), AND as unlinked-mention scan strings.
7. Tags: scan body text for `#`-tokens outside link/URL spans, applying the
   char-class + "not purely numeric" rule; separately read `tags:` frontmatter
   list. Union both per note, case-fold for identity, keep first-seen casing
   for display. Respect `/`-nesting as prefix-match for "tag X includes tag
   X/Y".
8. Frontmatter: parse YAML (or JSON) block; type-aware handling matters only
   for `tags`/`aliases`/`cssclasses` graph-wise — other typed properties are
   inert for connection purposes except that **Date properties can become
   links to daily notes if the Daily Notes plugin/convention is in play** —
   flag as a possible extra edge source if VaultSync's target vault uses daily
   notes.
9. Backlinks = reverse index of resolved links (+ probably embeds, verify).
   Unlinked mentions are a *separate*, non-graph, plain-text-substring search
   respecting Excluded Files — do not conflate with real edges when reporting
   "what connects to what," but do surface them if replicating the full
   Backlinks pane experience.
10. Embeds transclude content; for a faithful "human view," rendering an
    embedded note's heading/block section requires the same heading/block
    resolution logic as link navigation (§1), not just whole-file embedding.

## Verified vs. assumed

**Verified against official docs/API (with source):**
- All link/embed syntax forms and their meaning (§1) — `obsidian-help` repo,
  `Linking notes and files/*.md`.
- `.md` extension optional for notes, required for other file types.
- "New link format" setting's three modes and that it's write-only, not a
  resolution-order spec — `User interface/Settings.md`.
- `fileToLinktext`'s exact duplicate-name policy ("unique → filename, else
  full path") — `obsidian.d.ts`.
- `resolvedLinks`/`unresolvedLinks` shape (path→path→count vs path→string→count)
  — `obsidian.d.ts`.
- Tag character rules, case-insensitivity + first-seen-casing display, nested
  tag prefix-matching semantics — `Editing and formatting/Tags.md`.
- Seven property types and their individual quirks, the three
  graph-special properties, the deprecated singular aliases and their 1.9
  cutoff — `Editing and formatting/Properties.md`.
- Alias → canonical-link-with-display-text resolution behaviour, alias
  participation in unlinked mentions — `Linking notes and files/Aliases.md`.
- Linked mentions vs. unlinked mentions definitions, Excluded-Files respect —
  official Backlinks page (obsidian.md/help/plugins/backlinks).
- Attachment default-location modes — `Editing and formatting/Attachments.md`.
- `CachedMetadata` keeps `links` and `embeds` as **separate arrays**, plus a
  separate `frontmatterLinks` array — `obsidian.d.ts`.

**Assumed / inferred, NOT directly confirmed — empirical-test list:**
- Exact tie-break order when multiple files share a basename (which one a bare
  `[[Note]]` resolves to). Community reports confirm the ambiguity exists;
  no doc states the precedence.
- Whether `resolvedLinks`/backlinks fold in `embeds` alongside `links`, or
  keep them separate internally while still surfacing embeds in the
  Backlinks pane as "linked mentions." Both readings are plausible from the
  API shape; not stated explicitly.
- Case sensitivity of link/basename resolution on a case-sensitive filesystem
  (Linux) — docs only confirm tag matching is case-insensitive; file
  resolution case behaviour is unstated and matters a lot for a git-hosted
  vault likely served from Linux containers.
- The precise char-span rule separating an inline `#tag` from a `#` used
  inside a link/URL is reconstructed from separate syntax rules, not stated
  as one unified grammar anywhere.
- Whether `getFirstLinkpathDest`'s resolution prefers a match relative to the
  source note's folder over a shorter vault-wide match, or vice versa, when
  both exist — `.d.ts` comment is silent on precedence.

## Implications for the rest of VaultSync

- The link-query CLI must consume the resolved / unresolved / backlink shapes above rather
  than inventing its own; see `agent-access.md`.
- Attachment default-location only matters if VaultSync ever writes attachments
  programmatically. For read and for the sync daemon it is inert.

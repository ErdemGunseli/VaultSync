# `daemon/` — operator notes

The project overview, design laws, configuration table and install steps live in the
[repo root `README.md`](../README.md); `docs/` carries the architecture. This file is the
operator reference for the two behaviours of `bridge.sh` that are easiest to get wrong in
practice: which of the two transports carries your `.obsidian/` folder, what happens when a
collision lands somewhere Obsidian cannot render, and the opt-in image compression that is
the one place this daemon rewrites your files.

---

## Two transports move a bridged vault, and only one carries `.obsidian/`

This is the single most confusing thing about a bridged vault, and it cost a full day before
it was understood. There are **two** hops between your git repo and your phone, they are
independent, and they do not agree about configuration:

```
GitHub  <--- git, carries EVERYTHING tracked --->  VAULT_DIR on the worker
VAULT_DIR on the worker  <--- Obsidian Sync, SELECTIVE --->  your devices
```

The first hop is git. It carries every tracked byte, `.obsidian/` and all fourteen of your
plugins included. Nothing about it is selective.

The second hop is Obsidian Sync, and Sync carries `.obsidian/` **only when it has been told
to, per vault, in eight named categories**. `ob sync-setup` — the command this daemon uses to
link a vault — writes no such setting at all, and Sync reads an absent setting as *none*. So
the default state of a freshly linked vault is **config syncing entirely off**.

### The symptom, and why it is so hard to diagnose

Every device shows **"You currently have 0 plugins installed"**, with Restricted mode off and
the Sync toggles for *Core plugin settings*, *Active community plugin list* and *Installed
community plugins* all switched **on**.

Those toggles are not lying and they are not the problem. They control what a device is
willing to **receive**. If the remote was never given the plugins, there is nothing to send
down, and a device configured perfectly still shows zero. Both halves have to be right:

| Where | What it controls | Symptom when wrong |
|---|---|---|
| The daemon (`VAULT_SYNC_CONFIGS`) | what the worker **uploads** into the Sync remote | every device shows zero, however its toggles are set |
| The device (Settings → Sync → toggles) | what that device **downloads** | that one device shows zero, others are fine |

So: **if one device is missing plugins, check that device. If every device is missing them,
check the daemon.**

### What the daemon does now

`bridge.sh` passes `--configs` on **every** `ob sync-config` call, and its default is all
eight categories Obsidian Sync exposes:

```
app, appearance, appearance-data, hotkey,
core-plugin, core-plugin-data, community-plugin, community-plugin-data
```

`community-plugin-data` is the one that carries the installed plugin files; `core-plugin` and
`core-plugin-data` cover the built-ins; `appearance-data` covers themes and CSS snippets.

That is the right default for *this* daemon specifically: it exists to bridge a vault whose
`.obsidian/` is versioned in git, and carrying the notes but not the configuration that
renders them is the wrong half of the job.

The flag is now always passed, empty included, because omitting it is **not** "use a default"
— `ob` leaves whatever is already stored untouched when the flag is absent, which is exactly
how a vault stayed at *none* forever.

### It is logged, in two places

A silent configuration decision is what made this expensive. At link time:

```
[vault-bridge:planning] sync-config: asking Obsidian Sync to carry config categories:
                        app,appearance,appearance-data,hotkey,core-plugin,core-plugin-data,community-plugin,community-plugin-data
```

and in every heartbeat, so the state is answerable from logs at any moment, not only at boot:

```
[vault-bridge:planning] heartbeat: HEAD=a1b2c3d uncommitted=0 poll=15s ob=1 ob_quiet=42s configs=ok:app,appearance,…
```

`configs=` reads `<state>:<list>`, where state is `ok` (applied), `FAILED` (the call was
rejected — the category names and the conflict strategy are both unchanged) or `unset` (the
vault is not linked to Sync at all).

### Applying it to a vault that is already linked

`ob sync-config` is idempotent and the daemon re-asserts it on **every boot**, including for a
vault that is already linked. A redeploy is therefore all that is needed to heal a vault that
was linked under the old behaviour — no unlink, no re-link, no re-download.

The first sync pass after that redeploy uploads `.obsidian/` to the Sync remote; devices pick
it up on their next sync, and Obsidian asks to restart once the plugin files land.

### Carrying less

`VAULT_SYNC_CONFIGS` still overrides, and takes any comma-separated subset of the eight names
above:

```bash
VAULT_SYNC_CONFIGS=app,appearance,core-plugin,community-plugin   # settings, no plugin files
VAULT_SYNC_CONFIGS=                                             # carry no config at all
```

An **explicitly empty** value means off, and the daemon says so loudly rather than quietly
falling back to the default. Note that only the secret-file and plain deployment modes can
express "explicitly empty"; the env-group mode skips empty values, so a vault there falls back
to the full default.

An invalid category name makes `ob sync-config` reject the **whole** call, taking the conflict
strategy down with the categories — which is why the default list is pinned literally in
`bridge.sh` and checked against `ob sync-config --help` when the pinned `obsidian-headless`
version in the `Dockerfile` is bumped.

---

## Collisions under a hidden path stop the daemon, on purpose

A same-region collision git cannot merge is normally resolved the way Obsidian Sync resolves
its own: your device's version stays in the note, the other side is committed beside it as
`Note (conflicted copy <timestamp>).md`, and you see both on every device. The vault's
`.gitignore` deliberately does **not** ignore those copies — being visible is the entire
mechanism.

That mechanism does not work under a hidden path. Obsidian renders neither dotfolders nor
dotfiles, so `.agent-memory/sessions/x (conflicted copy …).md` is committed, pushed, and read
by nothing. The conflict looks resolved and is not; its only trace is a line in a server log.

So a collision on any path with a **component beginning with a dot** takes the loud branch
instead:

```
[vault-bridge:planning] CONFLICT under a hidden path - '.agent-memory/sessions/x.md'
[vault-bridge:planning]          NO conflicted copy was made: Obsidian shows neither dotfolders nor
[vault-bridge:planning]          dotfiles, so the copy would be invisible on every device …
```

No copy is written, the merge is aborted, the working tree is left exactly as it was, and
both sides remain in git history. **Git sync for that vault is stalled until it is resolved** —
the daemon keeps committing local edits but cannot push past the divergence, and it repeats
the warning every pass rather than going quiet.

To resolve one: clone the vault repo, merge the branch by hand, push. The daemon
fast-forwards on its next pass.

### `.obsidian/` is included, deliberately

It is the dotfolder that collides most often, which is the argument *for* including it rather
than against: it would otherwise be the largest single source of copies no device can render.
Its files are also machine-read configuration, not prose — nobody reconciles two versions of
`community-plugins.json` by reading them side by side, so a copy there is litter that never
gets cleaned up, replicated everywhere.

The cost is real and accepted: an `.obsidian/` collision stalls git sync until a human
resolves it, where before it silently produced an invisible file. A loud stall is the better
failure. The recommended vault `.gitignore` (`vault.gitignore.example`) already excludes the
high-churn per-device state — `workspace.json`, caches, plugin `data.json.bak` — so what is
left in `.obsidian/` is low-churn configuration that genuinely should not be diverging in two
places at once. Install it; without it this branch fires far more often than it needs to.

---

## `VAULT_COMPRESS_IMAGES` — off by default

Obsidian Sync (Standard) refuses files over 5 MB, so the daemon refuses to commit them: a
file that size would reach the repo and never reach a phone. That refusal is unchanged and
remains the floor.

`VAULT_COMPRESS_IMAGES=1` adds one option before the refusal: an image **already over the
cap** may be re-encoded in place to try to fit under it.

**This is the only place the daemon rewrites the contents of a file.** Everywhere else it
moves bytes and resolves conflicts without ever looking inside one. A re-encode is lossy and
irreversible, and for a photo pasted from a phone the vault may hold the only remaining copy
— which is why it is opt-in rather than the default, and why the guard rails below are not
negotiable:

| Guard | Behaviour |
|---|---|
| Off by default | Unset, `0`, or anything not truthy: nothing changes for anyone. |
| Only over the cap | A file at or under `VAULT_MAX_FILE_MB` is never opened, never touched. |
| Explicit allowlist | `.jpg .jpeg .png .webp` only, case-insensitive. `.gif` is excluded (it would lose animation), `.svg` (vector — there is no re-encode, only rewriting markup), `.heic`/`.tiff` (Obsidian does not render them, so a lossy rewrite buys nothing). |
| Never git-LFS | An LFS-tracked path is committed as a small pointer whatever the working tree holds, so re-encoding it would destroy pixels for zero gain. Skipped, and logged. |
| Same format | The output format is taken from the file's own extension, so a link in a note never breaks and a mislabelled file cannot silently change type. |
| Least destructive first | Quality 88 at original size, then 80/2560px, 72/1800px, 64/1280px. It stops at the **first** rung that fits. Never upscales. |
| Logged | `COMPRESSED: 'Attachments/photo.jpg' 12 MB -> 3 MB (vips, quality 80, longest side 2560px) - now under the 5 MB sync cap, committing it` |
| The refusal is still the floor | If no rung gets under the cap, the original is left untouched on disk and withheld from the commit exactly as before. A still-oversized file is never committed. |
| Atomic write-back | The re-encode is written to scratch on the vault's own volume, fsynced, and moved over the original with `rename()`. At every instant the file on disk is one whole image or the other. |

Nothing is written back unless the result is both smaller than the original **and** under the
cap; the original file is replaced only at that point, so a failed or partial encode cannot
leave a damaged file behind.

### Why the write-back is a rename and not a copy

This is the one path where **git holds no fallback copy**. A file only gets here by being
over the cap, which means it was refused and therefore never committed — so if the write-back
is interrupted half way, the surviving fragment is the only thing left, anywhere.

The obvious implementation, `cat "$tmp" > "$photo.jpg"`, has exactly that hole: `>` truncates
the destination the moment it opens it, and the user's only copy is gone for the whole
duration of the copy. Killed part way through a 3 MB image, that leaves 4096 bytes and
nothing else. So the re-encode is instead written beside the destination, fsynced, and
`rename()`d into place — atomic within one filesystem, so a reader (or a crash, or a redeploy)
sees the whole original or the whole re-encode and never a fragment.

Two consequences worth knowing, because the trade is real:

- **The scratch file lives under `VAULT_DIR/.git/`**, not `/tmp`. It has to be on the
  destination's filesystem or `mv` degrades to a cross-device copy with the same hole; and
  `.git` is the one place on that volume git never tracks and the inotify watch already
  excludes, so a scratch file left by a kill cannot be committed by the next pass.
- **The destination's inode changes.** Mode and ownership are copied across deliberately, but
  a pre-existing hardlink to the image keeps pointing at the old content. Nothing in this
  system consults a vault file's inode — the watch is recursive over directories, and git
  stores content — so atomicity is the better half of that trade.

`test_atomic_replace.sh` pins all of it, including a loop that kills the swap part way through
a 64 MB payload and requires a whole file every time.

### Turning it on, per deployment mode

`entrypoint.sh` decides which `VAULT_*` keys reach each bridge, and the three modes do not
agree about this one. Measured, not assumed:

| Mode | `VAULT_COMPRESS_IMAGES` in the container env | `VAULT_<n>_COMPRESS_IMAGES` |
|---|---|---|
| Secret files (`vault-<name>.env`) | reaches every vault | n/a — set it in the vault's own file, which works |
| Plain single vault | works | n/a |
| Env group (`VAULT_1`, `VAULT_2`, …) | reaches every vault | **silently ignored** |

The env-group row is a gap, not a design: that mode maps a fixed list of per-vault keys
(`BRANCH`, `SYNC_REMOTE`, `SYNC_ENCRYPTION_PASSWORD`, `SYNC_CONFIGS`, `DEVICE_NAME`,
`MAX_FILE_MB`) and `COMPRESS_IMAGES` is not on it, so `VAULT_1_COMPRESS_IMAGES=1` sets
nothing and reports nothing. Until that list gains the key, an env-group deployment can only
switch compression on for **every** vault at once, via the container-wide variable.

### The tool

The container installs **libvips** (`libvips-tools`, the `vips` CLI) — chosen over ImageMagick
because this process holds a push token for every vault it bridges, so the decoder it points
at untrusted image bytes is a real attack surface, and libvips is both markedly smaller and
has the better CVE record. `python3` with Pillow is used as a fallback if `vips` is absent,
which is what a bridge running outside the container will usually find.

If **neither** is present, compression cannot happen. It then behaves exactly as if the flag
were off — the file is refused — and says so rather than silently doing nothing:

```
COMPRESS: 'Attachments/photo.jpg' is over the cap and VAULT_COMPRESS_IMAGES is on, but no image
          tool is available (install libvips-tools, or python3 with Pillow).
          Refusing the file exactly as if compression were off.
```

### Compressing at the edge is still better

The device that took the photo still holds the original, so compressing on paste (Obsidian's
`image-converter` plugin, for example) loses nothing that is not already duplicated.
Compressing at the daemon means the full-size original may only ever have existed in git
history. Treat this flag as the backstop for what slips past that, not as the primary
mechanism.

---

## Known quirk: the size cap and git-LFS

`enforce_size_cap` measures the **working-tree** file. An LFS-tracked blob is therefore
refused at its full size even though what git would actually commit is a small pointer, so
LFS is not an escape hatch from the cap. This is long-standing behaviour and is deliberately
**unchanged** here — compression only declines to touch such a path, it does not alter how the
cap measures it. Exclude large media from the vault repo, or raise `VAULT_MAX_FILE_MB`
knowing Sync will not carry the file to devices either way.

---

## Tests

```bash
bash daemon/test/run.sh
```

`test_sync_configs.sh`, `test_conflict_dotfolder.sh` and `test_image_compression.sh` cover the
three behaviours above. They follow the house style described in the root README: the real functions are extracted
from `bridge.sh` and executed against real git repositories, every case asserts the scenario
was actually constructed before asserting the outcome, and each new behaviour has been
mutation-tested — broken on purpose to confirm the test goes red.

# `daemon/` — operator notes

The project overview, design laws, configuration table and install steps live in the
[repo root `README.md`](../README.md); `docs/` carries the architecture; a guided setup that
writes the install prompt for you lives at [grok-obsidian.vercel.app](https://grok-obsidian.vercel.app). This file is the
operator reference for the two behaviours of `bridge.sh` that are easiest to get wrong in
practice: which of the two transports carries your `.obsidian/` folder, what happens when a
collision lands somewhere Obsidian cannot render, and the opt-in image compression that is
the one place this daemon rewrites your files.

---

## Storage pressure, delivery receipts and worker footprint

The worker checks free bytes **and** free inodes on both the vault and Sync-state
filesystems before cloning, starting/restarting native Sync, or reconciling Git. It checks
again every loop while Sync runs. Below 128 MiB or 1,024 free inodes it pauses Git writes
and sends SIGTERM only to its own recorded native Sync child. Recovery requires 256 MiB
and 2,048 inodes, preventing repeated starts at the reserve boundary. It resumes the same
vault and state automatically; the storage guard never removes a Sync lock, resets
history or deletes working files to recover space. Probe failures also block writes. These reserves are a
headroom guard, not a reservation against other processes filling the disk between checks.

An interrupted merge, cherry-pick, revert or rebase, an unmerged index, or a missing/empty
index against a populated HEAD also pauses startup and reconciliation. The receipt names
the recovery state. The bridge preserves the working bytes and index stages for explicit
recovery; ordinary `git add -A` must never turn existing conflict markers or a lost index
into a successful delivery. Known new `--no-checkout` clones initialize and verify their
index before this normal check applies.

Before any Git merge or fast-forward modifies the working tree, the bridge stops only
its managed native Sync child and confirms that it has exited. Native Sync resumes
only after known clean completion or a successfully verified abort, with a clean index
and worktree, no pending operation, no shutdown request, and adequate storage. Final
Native saves that arrive during fetch defer the incoming merge until the next local
commit; size-cap-held bytes are retained rather than reset to force a merge.

Every bridge-managed checkout or incoming merge first creates and fsyncs a private
`.git/vaultsync-mutation-intent`, including its parent directory. Fresh clones always
use `--no-checkout`, then initialize their working tree under that fence. A crash or
failed fast-forward can leave partial files without `MERGE_HEAD`: any leftover intent,
including an empty file or symlink, holds startup and reconciliation. Only the process
that created the exact unchanged marker can clear it after verified clean completion.
Unknown intents are never automatically deleted, and no reset or clean attempts to
repair partial bytes. Node 22, already included in the Docker image, supplies the durable
file operations and is required for bridge-managed checkout and merge mutations.
A child that refuses to stop also holds the merge. Status checks, local commits,
fetches and idle passes do not restart native Sync.

Shutdown signals set a flag; the loop exits after a timed read/wait returns, then performs
cleanup through EXIT. This avoids a Bash read deadline interrupting a long signal trap
and resuming writers. Idle sleeps and cache maintenance have owned, interruptible waits.
Bounded foreground `ob` authentication/setup calls can still defer traps in a bare shell;
the production Docker entrypoint uses `tini -g` to forward signals to their descendants.

The pinned headless client reports **any** lock-acquisition filesystem failure as
"Another sync instance is already running", including ENOSPC. A repeated message is not
evidence that a lock is stale or safe to remove. Check the storage receipt first.

Each vault writes a private atomic JSON receipt outside the persistent data volume at
`/tmp/vaultsync-health/<vault-name>.json` (on macOS, the physical `/private/tmp` path).
`VAULT_HEALTH_DIR` can choose a different absolute directory outside the vault and Sync
state; symlinked paths and directories owned by another user are refused. The directory
is mode 0700, receipts 0600. Receipts contain state enums, counts, timestamps and Git
hashes; no note text, paths or authenticated URLs. `status` is `blocked`, `degraded` or
`healthy`. Explicit Git-only operation is identified by `sync_mode: git-only`; a configured
but failed or uninitialized native transport stays degraded even when Git is working.

`updated_at` proves only that the loop wrote a receipt. `last_fetch_success`,
`last_push_success`, `last_git_reconcile_success` and `last_sync_success` are separate clocks;
failed operations never advance them. Native startup, a live PID and error messages do
not count as Sync progress: only an actual `Fully synced` cycle updates the native clock.
A new native process must complete its own cycle before becoming ready. Git stage,
commit, status, fetch, merge and push failures publish a static reason and numeric exit
code; captured stderr is never printed because it can contain credentials. A stale or
missing receipt needs an external observer: these local files alone cannot alert anyone
when the container itself is stopped. Git hashes describe the last observed remote fetch,
not proof that every device has received a particular file.

| Variable | Default | Purpose |
|---|---:|---|
| `VAULT_STORAGE_MIN_BYTES` | `134217728` | Block below this free-byte reserve. |
| `VAULT_STORAGE_RESUME_BYTES` | `268435456` | Require this much headroom to resume. |
| `VAULT_STORAGE_MIN_INODES` | `1024` | Block below this many free inodes. |
| `VAULT_STORAGE_RESUME_INODES` | `2048` | Require this many inodes to resume. |
| `VAULT_EXCLUDE_AGENT_MEMORY` | `0` | Opt in to excluding only `/.agent-memory/` from this worker checkout. |
| `VAULT_CHECKOUT_PROFILE` | `full` | `obsidian` materializes visible paths, root `.obsidian/`, and `.gitignore`/`.gitattributes` at every depth; other hidden Git-only files stay in the index/history. |
| `VAULT_LFS_CACHE_BUDGET_BYTES` | unset | Opt in to bounded, remotely verified LFS cache maintenance, e.g. `536870912` (512 MiB). |
| `VAULT_LFS_CACHE_INTERVAL` | `300` | Seconds between bounded cache-maintenance attempts. |

Footprint options are per vault: in indexed deployment use
`VAULT_1_CHECKOUT_PROFILE=obsidian` and `VAULT_1_LFS_CACHE_BUDGET_BYTES=536870912` for the
intended worker, using its actual configured index. Global footprint flags do not leak
into indexed/file-mode siblings. Shared storage reserves and health-directory settings
apply globally unless a vault's own secret file overrides them.

The sparse options retain the complete Git index, history and origin, so `git add -A`,
fast-forwards and ordinary divergent merges retain the excluded bytes. New clones use
`--no-checkout`, configure the exclusion and initialize the sparse index **before** any
checkout can materialize Git-only archives. Existing clean copies can be omitted.
Dirty, staged, untracked or ignored bytes in excluded paths cause refusal with all bytes
retained. No cleanup, reset or source deletion is performed. The `obsidian` profile
omits root and nested hidden paths such as `.agent-memory/` and `Course/.sources/`,
while retaining all descendants of the root `.obsidian/` and the Git ignore/attribute
files required at every depth, including inside otherwise excluded parents. Attributes
retain their normal nested precedence and Git LFS behavior. Only the exact prior
`VAULT_EXCLUDE_AGENT_MEMORY=1` policy can migrate automatically; a different custom sparse
policy is refused unchanged. `full` retains existing behavior, including that legacy
flag when set; `obsidian` takes precedence when both options are present.
Changing a checkout policy requires a clean index and worktree. An unchanged policy
with no excluded materialized files does no checkout mutation, so legitimate pending
visible saves can enter normal reconciliation after restart.

Enable the profile only on the bridge worker, which has no consumer for Git-only archive
materializations. It changes no repository bytes, Git history, origin, or owner-device
checkout. It does not bound history/object-cache size: the storage guard and verified LFS
cache budget remain necessary. The non-cone policy uses a fixed seven-pattern definition,
rather than a generated list that grows with the repository.

The cache helper is independently callable in default dry-run mode:

```bash
node /app/cache-maintenance.mjs --repo-dir /data/vaults/example \
  --budget-bytes 536870912 --target-free-bytes 268435456
```

Add `--apply` only for the reviewed eviction. The helper verifies remote download
availability and local object identity before evicting derived `.git/lfs/objects` cache
entries. It does not delete working notes, remote objects or Git history. Maintenance
has explicit time/object/byte limits; insufficient verified cache space remains a
blocked state requiring a capacity change rather than a destructive cleanup. Automatic
maintenance runs before the storage wait so an already full disk can regain headroom,
and periodically thereafter. It uses the existing authenticated origin privately.

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

<div align="center">

# VaultSync

**Your Obsidian vault, everywhere — on your phone, in git, and in the hands of an AI agent.**

*One vault. Three consumers. No copies, no drift, no manual syncing.*

</div>

---

## The problem

An Obsidian vault is the best place to think. It is the worst place to collaborate with an
agent.

Obsidian Sync moves notes between **your devices** beautifully — and stops there. It has no
webhook, no API, no way for anything else to listen. Git moves notes between **machines and
agents** beautifully — and stops there too. Nothing on your phone speaks it. Put a vault in
git and your phone falls out of the loop; keep it in Sync and every agent is blind.

You end up choosing which half of your life your notes live in.

VaultSync refuses the choice.

```
                    ┌──────────────────────────────────────┐
   📱  phone ───────┤                                      │
   💻  laptop ──────┤          Obsidian Sync               │
   📋  tablet ──────┤                                      │
                    └──────────────────┬───────────────────┘
                                       │
                            ┌──────────▼──────────┐
                            │   VaultSync daemon  │   always-on, headless
                            │  the only member of │   the one process that is
                            │  the Sync mesh that │   awake when you are not
                            │     speaks git      │
                            └──────────┬──────────┘
                                       │
                    ┌──────────────────▼───────────────────┐
                    │        git  ·  source of truth       │
                    └──────────────────┬───────────────────┘
                                       │
   🤖  agents ──────────────────────────┘   clone · read · grep · write · push
```

Edit a note on your phone in a lift. It is a commit before you reach the lobby. An agent
rewrites twenty notes at 3am; they are on your phone at breakfast.

---

## Why a daemon, and not something simpler

This is the question worth interrogating, so here is the honest answer.

Obsidian Sync has **no webhook and no server-side API**. The only way to learn that a note
changed is to *be a client with the connection open*. That is a process, and it has to be
awake when you are not — which rules out a cron, your laptop, and your phone.

The obvious alternative is the **Obsidian Git plugin**, and it was evaluated fairly rather
than dismissed. Its own maintainer currently describes it as *"very unstable"* on mobile and
says *"I would not recommend using this plugin on mobile"* — root-caused to `isomorphic-git`
loading whole packfiles into a mobile JS heap, an architectural ceiling rather than a bug
queue. Even if that were fixed tomorrow, the plugin is a **foreground UI trigger**: it can't
sync while no Obsidian client is open, which is exactly the window that matters.

So: one small always-on process. That is the whole justification, and if Obsidian ever ships
a webhook, this project should delete itself.

---

## Design laws

These are not aspirations. They are enforced in code and covered by tests.

**git is the source of truth.** Sync is a device transport, not the record. Every
disagreement resolves toward git.

**Conflicts resolve the way Obsidian Sync resolves them — never worse, never silently
destructive.** Sync's own default auto-merges concurrent edits, and so does the bridge:
divergence between git and the vault is resolved by a real merge, and edits to different
parts of a note flow together exactly as they would under plain Sync. A genuine same-region
collision becomes an Obsidian-style **"Note (conflicted copy …).md" committed into the
vault** — it appears on your devices, inside Obsidian, precisely where Sync's own conflicts
appear, with your device's version kept in the main note. Pushes are *never* forced, and git
history keeps every side of every conflict, so nothing is ever lost — the safety net is
strictly stronger than Sync's version history.

**Fail soft, and say so.** No credentials means idle, not crash. No Obsidian auth means
git-only mode *with a warning* — agents keep syncing, phone-only edits do not, and the log
says which. Silence is never the failure mode.

**Nothing may block on a prompt.** Every `ob` call reads stdin from `/dev/null`. A missing
credential fails in a second instead of hanging invisibly forever.

**Refuse rather than corrupt.** If the vault declares Git LFS filters and `git-lfs` is
missing, the daemon exits. Committing would write pointer files where your images should be —
corruption you'd discover months later opening a broken note.

**Fast, but debounced.** A local edit is picked up by `inotify` and reaches the remote in
roughly 1-2 seconds — not the old fixed 15-second poll. A burst of continuous writes (Obsidian
saves on every keystroke) is debounced into one commit rather than one per keystroke. Remote
polling is adaptive: quick while there's been recent activity, backing off toward an idle rate
otherwise. If `inotify-tools` is ever missing at runtime, the daemon falls back to
interval-only polling with a WARNING rather than losing local-edit detection silently.

**Never commit past the Sync cap.** Obsidian Sync (Standard plan) refuses files over 5MB. A
file that size committed via git would reach the repo but never reach a device — silent
divergence. The daemon refuses to commit an oversize file (unstaging it, not deleting it) and
warns loudly, every pass, until it's resolved.

---

## Configuration is the enablement

There is no manifest and no `enabled` flag to keep in sync with anything. **A vault exists
because its config does.**

**One vault** — set `VAULT_REPO` as a plain environment variable. Done.

**Several vaults** — either name them in one env group (`VAULTS=planning,personal` plus
`VAULT_<NAME>_REPO` / `_SYNC_REMOTE` / `_SYNC_ENCRYPTION_PASSWORD` per vault — one Render
env group defines the whole service), or drop one file per vault at
`$SECRETS_DIR/vault-<name>.env`. Either way, adding a vault is adding config; removing one
is removing it.

### Adding a vault is three things, not one

1. Its config keys (repo URL, Sync remote name).
2. **Extending `GIT_TOKEN` to the new repo.** Fine-grained PATs enumerate repositories
   explicitly — a newly created repo is *never* covered by an existing token. Edit the
   token's repository list, or mint a fresh one.
3. **Its encryption password**, if the new Sync remote is end-to-end encrypted.

The daemon catches the half-done states instead of half-working: a name listed with no
repo key warns loudly at boot ("HALF-ADDED"), a `REPLACE_ME` placeholder anywhere in a
vault's config is fatal with a message naming the fix, and a clone failure hints at PAT
coverage rather than leaving a bare auth error.

See [`daemon/secrets.example/vault-planning.env`](daemon/secrets.example/vault-planning.env)
for every key, each with a comment explaining why it exists.

### Authentication

Use **`OBSIDIAN_AUTH_TOKEN`**. The headless client reads it straight from the environment, so
the daemon never runs a login — which means **account MFA is simply irrelevant**. Get it by
running `ob login` once anywhere and reading
`${XDG_CONFIG_HOME:-~/.config}/obsidian-headless/auth_token`.

Email and password are a fallback that cannot work on an MFA-protected account, because a
static password can't produce a rotating code.

If your remote vault is end-to-end encrypted, `VAULT_SYNC_ENCRYPTION_PASSWORD` is **required**.
Obsidian's E2E is zero-knowledge — the server never sees it, so no account token can derive
it. Omit it and `ob sync-setup` prompts, and a prompt in a background worker is an invisible
hang.

---

## Install the vault's `.gitignore` first

Do this before the first sync, not after.

Copy [`daemon/vault.gitignore.example`](daemon/vault.gitignore.example) into the root of your
**vault content repo**. Without it, per-device UI churn and Obsidian Sync's own conflict
copies get committed on the very first pass and are then permanent in your history.

It deliberately does *not* ignore `.obsidian/` wholesale — your plugin and theme declaration
is real configuration worth versioning, and agents are meant to be able to change it.

---

## Running it

Outbound-only. No ports, no inbound HTTP, no health endpoint to serve. It runs anywhere with
a persistent volume at `/data`.

```bash
docker build -t vaultsync ./daemon
docker run -d --name vaultsync \
  -v vaultsync-data:/data \
  -e VAULT_REPO="https://<token>@github.com/you/your-vault.git" \
  -e OBSIDIAN_AUTH_TOKEN="..." \
  -e VAULT_SYNC_REMOTE="Your Vault" \
  vaultsync
```

[`daemon/render.yaml`](daemon/render.yaml) provisions it as a Render background worker, but
nothing in the image is Render-specific. Moving hosts is: recreate the service, re-add the
secrets. No code change.

**State lives on the disk and must stay there.** The auth token and each vault's `state.db`
live in one shared `XDG_CONFIG_HOME` (default `/data/ob-state`). Lose it and you force a full
re-sync; commit it and you leak credentials into your notes.

---

## Tests

```bash
bash daemon/test/run.sh
```

They are **behavioural**. They run the real entrypoint and the real daemon against real git
repositories and assert on what actually happened — that edits move in both directions, that
a divergence is surfaced rather than force-pushed, that git-only degradation is announced,
that a stray global variable can't collapse every vault onto one repo, that a local edit
reaches the remote in seconds via `inotify` (falling back cleanly when it's absent), that a
burst of continuous writes debounces into one commit, and that a file over the Sync cap is
withheld and warned about while its siblings still sync. Nothing greps the source, so a rename
cannot fake a pass and inverted logic cannot slip through.

---

## Status

| Component | State |
|---|---|
| **Sync daemon** | Built, tested (38/38), validated against `obsidian-headless` 0.0.14 |
| **Agent access skill** | Designed, specified in [`docs/`](docs/), not yet built |
| **Live deployment** | Not yet — needs a vault repo and credentials |

The daemon pins `obsidian-headless` by version on purpose. It is a `0.0.x` open beta whose
CLI has already changed shape between releases; three separate bugs in an earlier
implementation came from guessing at its interface instead of reading it. Re-check `ob --help`
before bumping.

---

## Documentation

| Document | What it answers |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | How the pieces fit, and what would make this design wrong |
| [`docs/agent-access.md`](docs/agent-access.md) | How an agent reads a vault, and why there is no MCP server |
| [`docs/isolation.md`](docs/isolation.md) | How a vault carries its own rules and skills without infecting other projects |
| [`docs/moving-hosts.md`](docs/moving-hosts.md) | Moving a vault or the whole daemon to another hosting account |
| [`docs/obsidian-link-semantics.md`](docs/obsidian-link-semantics.md) | What it actually takes to resolve `[[wikilinks]]` the way Obsidian does |

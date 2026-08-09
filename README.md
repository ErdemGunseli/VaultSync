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

**Surface conflicts. Never rewrite them.** Pulls are `--ff-only`. Pushes are *never* forced.
Sync is configured with `--conflict-strategy conflict` so it writes conflict files instead of
silently merging, and the daemon logs every one it sees. A divergence is a thing a human
decides, and the daemon's job is to make sure you find out.

**Fail soft, and say so.** No credentials means idle, not crash. No Obsidian auth means
git-only mode *with a warning* — agents keep syncing, phone-only edits do not, and the log
says which. Silence is never the failure mode.

**Nothing may block on a prompt.** Every `ob` call reads stdin from `/dev/null`. A missing
credential fails in a second instead of hanging invisibly forever.

**Refuse rather than corrupt.** If the vault declares Git LFS filters and `git-lfs` is
missing, the daemon exits. Committing would write pointer files where your images should be —
corruption you'd discover months later opening a broken note.

---

## Configuration is the enablement

There is no manifest and no `enabled` flag to keep in sync with anything. **A vault exists
because its config does.**

**One vault** — set `VAULT_REPO` as a plain environment variable. Done.

**Several vaults** — drop one file per vault at `$SECRETS_DIR/vault-<name>.env`.
`vault-research.env` creates the vault `research`. Adding a vault is adding a file; removing
one is removing a file. The filename is the vault's identity and always beats a `VAULT_NAME`
written inside the file, so two files can never collide on one sync state.

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
that a stray global variable can't collapse every vault onto one repo. Nothing greps the
source, so a rename cannot fake a pass and inverted logic cannot slip through.

---

## Status

| Component | State |
|---|---|
| **Sync daemon** | Built, tested (19/19), validated against `obsidian-headless` 0.0.14 |
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
| [`docs/obsidian-link-semantics.md`](docs/obsidian-link-semantics.md) | What it actually takes to resolve `[[wikilinks]]` the way Obsidian does |

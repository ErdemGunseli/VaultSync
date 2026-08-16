# Setting up a vault, start to finish

The division of labour: **the owner supplies four values; an agent does everything
else.** If you are an agent reading this, "everything else" is yours.

## What the owner does (once per vault system)

1. **Create the vault content repo** on GitHub (private, empty).
2. **Create the Sync remote** from any machine:
   `ob login`, then `ob sync-create-remote --name <Name> --encryption end-to-end`
   (omit `--password`; the prompt keeps the passphrase out of shell history).
   Generate the passphrase with a password-manager generator (6-7 random words) and
   store it there. Never paste a passphrase into a chat.
3. **Paste four values into the Render env group** (`vaultsync` on the hosting
   account), replacing the placeholders an agent has staged:
   - `OBSIDIAN_AUTH_TOKEN` - from `~/.obsidian-headless/auth_token` after `ob login`
     (macOS path; Linux: `~/.config/obsidian-headless/auth_token`). A trailing `%`
     in terminal output is zsh's no-newline marker, not part of the token -
     `pbcopy < ~/.obsidian-headless/auth_token` copies it exactly.
   - `GIT_TOKEN` - a fine-grained PAT covering the vault repo(s), Contents: Read
     and write. Fine-grained PATs enumerate repos explicitly: adding a vault later
     means extending this token's repo list.
   - `VAULT_n_SYNC_ENCRYPTION_PASSWORD` - the passphrase(s) from step 2.
4. **Connect devices**: in Obsidian, Settings → Sync → connect to the existing
   remote vault → passphrase. Local vaults live wherever Obsidian puts vaults,
   **never inside a git clone** - devices are deliberately git-free.

## What the agent does (everything else)

1. Push a seed tree (`vault-seeds/` here) into the new repo as its first commit -
   this ships the baseline: `.gitignore`, LFS patterns, the vault constitution,
   the persistence rule (changes push to main in the same turn), the `borrow`
   skill, and `.agent-memory/`.
2. Stage the env group: `VAULT_n` = repo URL (the identity), `VAULT_n_SYNC_REMOTE`
   = the Sync remote's exact name, placeholders for the secrets. One group defines
   the whole service.
3. Provision (or reuse) the worker: a Render background worker from
   `daemon/render.yaml` - starter plan, 5 GB disk at `/data`, autodeploy from this
   repo's `main`. Link the env group.
4. After the owner fills the values: trigger a deploy and **verify from the logs**,
   not from the exit code - both of these lines per vault, and no WARNINGs:
   ```
   [vault-bridge:<name>] reconcile loop: adaptive poll ...
   Device name: vault-bridge-<name>
   ```
   The second line means sync-setup succeeded, i.e. the passphrase was right.
5. Prove it end to end before calling it done: watch the vault repo for the
   owner's first device edit becoming a commit, then push a note and have the
   owner confirm it reached a device.

## Adding one more vault to a running system

Owner: repo + Sync remote + passphrase into a new `VAULT_n_SYNC_ENCRYPTION_PASSWORD`
slot + extend `GIT_TOKEN` to the new repo. Agent: seed the repo, add `VAULT_n` +
`VAULT_n_SYNC_REMOTE` to the group, redeploy, verify the two log lines. The daemon
catches every half-done state loudly (see the README's "three things, not one").

## Moving accounts

Configuration motion, not migration - see [`moving-hosts.md`](moving-hosts.md).

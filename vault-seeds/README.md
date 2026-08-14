# vault-seeds

Starting trees for two new Obsidian vaults, ready to become the initial commit of their own
git repos once you create them on GitHub:

- **`planning/`** - the shared, agent-orchestrated idea corpus. Extends
  `planning/vault-template/` from the QUANTSOC repo: same floor schema (title + state
  required, no numeric priority, ever), same GTD structure, plus agent rules
  (`.claude/rules/`, `.cursor/rules/`) and an append-only agent memory log
  (`.agent-memory/`).
- **`personal/`** - a minimal personal vault. Same sync infrastructure, no agent
  orchestration, no seeded structure beyond a starting folder. Deliberately sparse - you
  shape it.

## Using a seed

For each vault (`planning` or `personal`):

```bash
mkdir ~/my-new-vault && cd ~/my-new-vault
git init
cp -r /path/to/vault-seeds/<planning|personal>/. .
git add -A
git commit -m "Initial vault"
git remote add origin <your-new-github-repo-url>
git push -u origin main
```

Then point VaultSync's daemon at the new repo (see the daemon's own setup docs) and open the
folder as a fresh Obsidian vault.

## Why two separate seeds

The planning vault is meant to be opened, read, and written to by agents as a matter of
course - it carries rules that shape how they write into it. The personal vault is meant to
stay agent-light by default. Keeping them as separate seeds (rather than one vault with a
personal subfolder) means each repo's rules and skills apply only where they're wanted, and
gitignore/privacy boundaries don't have to be re-derived per subfolder. See
`../docs/isolation.md` for the deeper reason agent rules should not straddle a personal/shared
boundary within one vault.

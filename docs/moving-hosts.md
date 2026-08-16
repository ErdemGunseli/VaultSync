# Moving a vault (or the whole daemon) to another account

Nothing in the image or the vault state is tied to a hosting account. A vault's identity
lives in three places only: its git repo, its Obsidian Sync remote, and its env config.
Moving hosts is therefore configuration motion, not migration.

## Moving one vault to a different account's daemon

Useful when one vault needs a different trust boundary than its siblings (for example a
private vault leaving a team-visible account).

1. On the destination account: create a worker from `daemon/render.yaml` (any name), with
   its own env group: `VAULTS=<name>` plus that vault's `VAULT_<NAME>_*` keys,
   `OBSIDIAN_AUTH_TOKEN`, and a `GIT_TOKEN` scoped to that vault's repo only.
2. Deploy. The new daemon clones the repo, joins Sync as a new device, and reaches the
   same state on its own - there is nothing to copy. The Sync state on the old disk
   belongs to the old device identity and must not be moved.
3. On the source account: remove the vault's name from `VAULTS` and delete its
   `VAULT_<NAME>_*` keys. Redeploy. Narrow the source `GIT_TOKEN` so it no longer covers
   the moved repo - the move is not complete until the old credential cannot reach it.
4. Optionally clean the old service's disk (`/data/vaults/<name>`, and
   `/data/ob-state/sync/<name>`) on its next maintenance touch.

Brief double-running is harmless by design: two daemons on one vault behave like two
extra Sync devices that both push to git, and the merge semantics absorb it.

## Moving the whole daemon

Same as above for every vault at once: recreate service + env group on the destination,
fill the same keys, deploy, then suspend or delete the source service. The vault repos
and Sync remotes never notice.

## What must NOT move

- The persistent disk / Sync state (`/data/ob-state`): it encodes the old device
  identity. A fresh daemon builds fresh state; copying it across accounts invites two
  services believing they are the same Sync device.
- Credentials in bulk: mint per-destination tokens scoped to what that destination
  hosts, rather than carrying one broad credential everywhere.

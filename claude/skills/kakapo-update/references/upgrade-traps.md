# Upgrade traps, per component

Read the entry for every component that `version-jumps.py` lists under
WATCHED or MAJOR. Each says where its changes are written down, what has
broken before (here or upstream), and how to check it after the test.

Contents: nixpkgs itself · Immich · PostgreSQL and its extensions · kernel
and NVIDIA · AdGuard Home · nginx and the LAN proxy · ntfy · Grafana and
Prometheus · Tailscale, OpenSSH, systemd, iptables · sops-nix · ledger ·
cf (update-pins) · Gramps Web images · hasala · claude-code · a NixOS
release upgrade (26.05 -> 26.11)

## Finding the history of one package or module

Packages and modules that we take from nixpkgs change only through nixpkgs
commits. List the commits between the old and new lock date that touch one
path (no nixpkgs clone needed):

```sh
gh api "repos/NixOS/nixpkgs/commits?sha=<new rev>&since=<old date>T00:00:00Z&path=<path>" \
  --jq '.[] | "\(.sha[0:10]) \(.commit.committer.date[0:10]) \(.commit.message|split("\n")[0])"'
```

Useful paths: `pkgs/by-name/im/immich/package.nix`,
`nixos/modules/services/web-apps/immich.nix`,
`nixos/modules/services/databases/postgresql.nix`,
`nixos/modules/services/networking/adguardhome.nix`,
`nixos/modules/services/web-servers/nginx/default.nix`,
`nixos/modules/services/misc/ntfy-sh.nix`,
`pkgs/os-specific/linux/nvidia-x11/default.nix`. Use the `nixpkgs-unstable`
rev for Immich (its package and module come from there, see `flake.nix`) and
the `nixpkgs` rev for everything else. Confirm a path exists before relying
on an empty answer; files move.

A commit message with `BREAKING`, `rename`, `remove`, `deprecate`, or a
`mkRenamedOptionModule` in the diff is worth opening.

## nixpkgs itself (`nixos-26.05`)

The weekly bump moves within the release branch, so changes are backports:
security fixes and minor versions. Breaking changes are rare but not zero.
The release notes are in the source:
`$(nix eval --raw .#nixosConfigurations.kakapo.pkgs.path)/nixos/doc/manual/release-notes/rl-2605.section.md`.
Look at `evaluation warning:` lines from the build: a new warning about an
option we set means the module changed under us.

The lock never moves to a new release by itself: `flake.nix` names the
`nixos-26.05` branch. Moving to 26.11 is its own change (see the end).

## Immich (nixpkgs-unstable)

Highest data risk on the host. It holds Saleh's photo library.

- Read: <https://github.com/immich-app/immich/releases>, every release from
  the running version (`curl -s 127.0.0.1:2283/api/server/version`) to the
  new one. Look for "Breaking changes", "required version", database or
  storage-template changes, and removed environment variables.
- Migrations run on `immich-server` start and are one-way. Immich does not
  support downgrade, so anything that later starts the old Immich (a
  rollback, 04:00, another agent's master-based test) leaves an old server
  on a new schema. Patch releases can carry migrations too, so check every
  version change, patch included (empty output = no migration):

  ```sh
  m() { gh api "repos/immich-app/immich/contents/server/src/schema/migrations?ref=v$1" --jq '.[].name' | sort; }
  comm -13 <(m <old>) <(m <new>)
  ```

  (The compare API caps at 300 files, so do not grep its file list.) Any
  output makes it a *migrating change*; SKILL.md step 6 says how to handle
  one.
- Backups: Immich dumps its DB nightly at 02:00 to
  `/mnt/media/immich/backups` (mode 0700, owner `immich`; names carry the
  Immich and PostgreSQL versions, e.g. `...-v3.3.3-pg17.11.sql.gz`). The
  02:00 dump always runs before the 04:00 upgrade, so it covers a normal
  merge. For a test now, it is valid only if its version tag matches the
  running Immich and nothing important was uploaded since. For a fresh dump,
  ask Saleh to run **Database Backup** in Immich Administration > Jobs; do
  not improvise a `pg_dump`. Confirm it with
  `sudo ls -lt /mnt/media/immich/backups | head -3`. A restore needs the same
  PostgreSQL major and VectorChord version as the dump.
- The dump and the originals are on the same media SSD, and the repo has no
  off-host Immich backup. For an Immich major, ask Saleh in the Hold
  message whether he has a copy of `/mnt/media/immich` off that disk.
- Module changes on unstable can need new options or change defaults. Check
  `nixos/modules/services/web-apps/immich.nix` history as above.
- The swap to the unstable module is temporary (dropped on 26.11, see
  `flake.nix`). If the unstable module starts to need something only newer
  nixpkgs provides, the build or eval fails; that is a blocker for this
  bump, fixed in its own PR.
- Check after the test: version endpoint reports the new version;
  `journalctl -u immich-server -b` shows migrations finished, no errors;
  `immich-machine-learning` active; open `https://photos.salehtl.com` loads
  (or `curl -s 127.0.0.1:2283/api/server/ping` returns `pong`).

## PostgreSQL and its extensions (Immich's `services.postgresql`)

- The package comes from `system.stateVersion` (`25.11` gives
  `postgresql_17`), not from an explicit pin. Check the evaluated version:
  `nix eval --raw .#nixosConfigurations.kakapo.config.services.postgresql.package.version`.
- 17.x to 17.y: routine. Read the release notes
  (<https://www.postgresql.org/docs/release/>) only for "a reindex is
  needed" notes, which happen in some minors.
- A major change (17 to 18) on this service: **Do not merge**. The data
  directory `/var/lib/postgresql/17` needs a planned `pg_upgrade` (NixOS
  manual, "Upgrading PostgreSQL"), with a dump first. It can only appear if
  the default rule, the Immich module, or `system.stateVersion` changed;
  find which.
- `vchord` (VectorChord) and `vector` (pgvector): Immich manages these. A
  version change can need `ALTER EXTENSION ... UPDATE` and a reindex of the
  vector indexes, which Immich runs on start. Read VectorChord's release
  notes for the jump. Current versions:
  `sudo -u postgres psql -Atc "select extname, extversion from pg_extension" immich`.
- hasala has its own PostgreSQL 17 (`hasala-postgresql`) pinned through the
  hasala input, which the weekly bump does not move. Never mix the two up.

## Kernel and NVIDIA driver

- Package names in the diff: `linux`, `nvidia-open` (`<driver>-<kernel>`),
  `nvidia-x11`, `nvidia-persistenced`.
- Any kernel or initrd change needs a reboot to run; `version-jumps.py` says
  so. Activation does not load the new kernel. Report "reboot needed after
  merge"; do not reboot.
- A driver change with the old module still loaded: `nvidia-smi` fails with
  "Driver/library version mismatch" until reboot, and `nvidia-persistenced`
  or the GPU exporter can fail in the guarded-test (exit 4). That is not a
  broken bump if the logs show only the mismatch, but guarded-test has then
  rolled back the whole system, so nothing else in the bump was tested on
  the host. See SKILL.md step 6.
- A driver build failure against a new kernel is a classic weekly-bump
  failure (the driver is unfree, never cached, compiled in CI). See
  `failing-bumps.md`.
- Nothing on the host uses CUDA (CLAUDE.md, hardware bullet), so only the
  exporter and persistenced depend on the driver.

## AdGuard Home

The house's only resolver. A broken AdGuard is an outage for every device.

- Read: <https://github.com/AdguardTeam/AdGuardHome/releases>. Look for a
  `schema_version` change in its YAML config, removed settings, and changes to
  `allowed_clients`, rate limit or DoH upstream handling.
- `services.adguardhome.mutableSettings = true` here, so AdGuard merges the
  module's settings into its own file. A new schema migrates that file
  in place on start (one way).
- `guarded-test.sh` rolls back if DNS stops answering. Also check filtering
  still works and the rate limit is still per client (CLAUDE.md, AdGuard
  bullet).

## nginx and the LAN proxy

- A failed reload keeps the old vhosts live and `guarded-test.sh` exits 4.
- Read the nixpkgs module history for directive or default changes
  (`recommendedProxySettings`, TLS defaults). Check `tailscale-nginx-auth`
  still gates: an unauthenticated LAN request to `https://grafana.salehtl.com`
  must get 401.
- `lan-proxy-dns` and `lan-proxy-spoof-check` must stay green
  (`systemctl --failed`).

## ntfy

- Read: <https://github.com/binwiederhier/ntfy/releases>. Look for auth or
  ACL changes (default access is deny-all here, anonymous may only publish to
  `kakapo`), and config key renames.
- Check: `curl -s 127.0.0.1:2586/v1/health` and that a `notify-failure@`
  test would still post (do not trigger one just to check).

## Grafana and Prometheus

- Grafana majors change `auth.proxy` and dashboard schemas. Read the "What's
  new" and breaking-changes pages. Proxy auth must still accept only
  `salehtl@github`.
- Prometheus majors can change the TSDB format; 90 days of data live in its
  state directory. Read the release notes.

## Tailscale, OpenSSH, systemd, iptables

These carry remote access and the firewall. Read their release notes for any
major or minor change. After the test: `tailscale status` works, SSH still
accepts keys only, `sudo iptables -C INPUT -j nixos-fw` succeeds (guarded-test
checks this too). Tailscale changes can affect the subnet route and exit
node: `tailscale status --json | grep -A4 PrimaryRoutes`.

## sops-nix

A change to `sops-install-secrets` can change how secrets reach
`/run/secrets`. After the test, check that services that read secrets
(ledger, ntfy, grampsweb, hasala, msmtp) are active and
`sudo ls /run/secrets/` still lists every service directory (names only;
never print secret contents).

## ledger (`github:salehtl/ledger`, follows nixpkgs)

Moves weekly with `main`. It backs up `ledger.db` before a new build first
opens it. Read the commits in the compare URL from `lock-diff.py` for schema
changes. The Nix build embeds `internal/web/dist` and never runs Node
(CLAUDE.md), so if commits change the frontend source but not
`internal/web/dist`, the verdict is **Hold: ledger dist not rebuilt**; hold
`ledger` back as in `failing-bumps.md` section 1. Check
`curl -s 127.0.0.1:8090/api/health` reports `"db":"ok"`.

## cf CLI (`scripts/update-pins.sh`)

Bumped to npm `latest` weekly in the same PR (`pkgs/cf/package.nix`,
`pkgs/cf/package-lock.json`). It is a CLI only, installed system-wide
(`hosts/kakapo/default.nix`); no service runs it. (`lan-proxy-dns.sh` has a
shell function also named `cf` that wraps `curl`; it does not use this CLI.)
`update-pins.sh` also re-resolves every transitive dependency weekly, and
the result runs on a host where agents have sudo. Check it:

1. `git diff origin/master -- pkgs/cf/package-lock.json` and list every
   added or changed `node_modules/<name>` with its version.
2. For each, `nix shell nixpkgs#nodejs -c npm view <name> time maintainers --json`.
   **Hold** if a version was published less than 7 days ago or the
   maintainers changed.
3. **Hold** on any new `"hasInstallScript": true` entry.
4. To hold cf back, take `pkgs/cf/` from `origin/master` on your own branch
   (`failing-bumps.md` section 1).

See also kakapo-security.

## Gramps Web images (by hand)

Pinned by tag and digest in `modules/services/grampsweb.nix`; the weekly
bump does not move them, and they do not appear in `diff-closures` (Docker
pulls them at start). Read
<https://github.com/gramps-project/gramps-web-api/releases> and the
frontend's releases. Confirm the digest belongs to the tag:
`docker buildx imagetools inspect <image>:<tag>`. State is under
`/var/lib/grampsweb` (tree DB, users DB); upgrades can migrate the users DB.

## hasala

Its rev is pinned in `flake.nix`; the weekly bump never moves it. Release
PRs come from `hasala-release.yml` and auto-merge unless labelled
`needs-review` (a migration or module change). For a `needs-review` PR,
read the migration files in the hasala compare, confirm they are
expand-only, and confirm `hasala-backup-premigrate` covers them (CLAUDE.md
"Release a new hasala version"). After the test check
`sudo hasala-admin version`, `systemctl is-active hasalad hasala-postgresql`,
`curl -s 127.0.0.1:9473/healthz` (expect `"db":"ok"`) and
`sudo curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8471/api/v1/healthz`
(expect 200). Without sudo, 8471 refuses the connection: the
`hasala-api-out` rule allows only root and hasala's UIDs, by design.

## claude-code (nixpkgs-unstable)

Changes several times a week and is usually harmless for the host. Note it
in the review; read its changelog only if the jump is large.

## A NixOS release upgrade (26.05 -> 26.11)

Not a weekly bump: it changes `nixpkgs.url` in `flake.nix`, so treat it as a
change (kakapo-change) and use this file for the review. Read
`rl-2611.section.md` in full. Required at the same time: drop the Immich
module swap and `pkgs.unstable.immich` (`flake.nix`,
`modules/services/immich.nix`), review `modules/ca-trust.nix`'s blacklist,
and leave `system.stateVersion` at `25.11`.

# Rolling back a bad merge on kakapo

Undo two things, in this order: what the **host runs now** (A), and what
**`master` will deploy at 04:00** (B). The host alone only lasts until 04:00;
`master` alone leaves the house broken until the revert is merged.

Variables from the deploy (step 1): `$prev_boot` (the boot default before the
deploy: the last deployed `master`, the rollback target), `$prev_run` (what ran
before; can be another agent's unmerged test), `<scratch>/guarded-test.sh` (the
pre-merge guard copy), `$out` (the merged build), `$sha` (the squash commit(s) to
revert).

## A. The host

### A1. guarded-test.sh already rolled back (exit 1 or 4)

It ran `$prev_run/bin/switch-to-configuration test`. Confirm:

```sh
readlink /run/current-system            # == $prev_run
host -W 2 one.one.one.one 10.0.0.215    # DNS answers
sudo iptables -C INPUT -j nixos-fw && sudo ip6tables -C INPUT -j nixos-fw && echo firewall attached
systemctl --failed --no-legend --plain
```

The boot default is untouched, so the host needs nothing more. If `$prev_run` is
not `$prev_boot`, the host now runs another agent's unmerged test; say so in the
report (it reverts on reboot). If the script printed
`ROLLBACK DID NOT RESTORE ...`, this is an incident: use kakapo-incident.

### A2. guarded-test.sh passed, but health failed later

Put the last deployed `master` back through the guard, so the lock and DNS watch
apply. Use `$prev_boot`, never `$prev_run`: that can be an unmerged branch, and
it is not GC-rooted once it stops running.

```sh
<scratch>/guarded-test.sh "$prev_boot" --replace   # the live system is your bad deploy
```

**If it exits 2**, DNS or the firewall is already down and the guard refuses to
act. This is the one permitted exception to "never a bare
`switch-to-configuration`": activate directly, under the same lock.

```sh
flock -w 900 /tmp/kakapo-guarded-test.lock sudo "$prev_boot/bin/switch-to-configuration" test
```

Then run the A1 checks. If DNS is still down, go to kakapo-incident.

If you already made `$out` the boot default, set it back yourself
(kakapo-incident does not touch the boot default):

```sh
sudo nix-env -p /nix/var/nix/profiles/system --set "$prev_boot"
sudo "$prev_boot/bin/switch-to-configuration" boot
readlink -f /nix/var/nix/profiles/system   # == $prev_boot
```

`nix-env --set` adds a new generation that points at `$prev_boot`; the bad one
stays for diagnosis.

If `$prev_boot` is unknown (session lost), pick the generation before the deploy
from the profile, not from guesswork:

```sh
sudo nixos-rebuild list-generations | tail -5
```

`readlink -f /nix/var/nix/profiles/system-<N>-link` is the store path to use.
Prefer the generation that was current before the merge (its build date predates
the merge); if unsure, use `/run/booted-system` when the host has not rebooted
since.

### A3. Data-bearing services

A rollback of the NixOS generation does not roll back state in `/var/lib`.
Check the module before reverting anything with migrations:

- hasala migrations are expand-only within a release, and
  `hasala-backup-premigrate` dumps first; a revert PR is the rollback.
- Immich (`pkgs.unstable.immich`) migrates its database on start and cannot
  downgrade. After an Immich version change, do not roll the host back to the old
  Immich. Stop `immich-server` only if it is already failing, then ask Saleh. The
  recovery is to restore the pre-upgrade dump from `/mnt/media/immich/backups`,
  not to change the generation.
- Others: read the module header. If a downgrade could corrupt state, stop the
  affected unit only if it is already failing, and ask Saleh.

## B. master

The 04:00 `nixos-upgrade` deploys `master` again, so fix `master` before then.
On a branch from `origin/master` in your clone:

```sh
git fetch origin
git switch -c revert-pr-<n> origin/master
git revert --no-edit <squash-sha>        # squash commits have one parent: no -m
nix fmt
out=$(nix build --no-link --print-out-paths .#nixosConfigurations.kakapo.config.system.build.toplevel)
nix store diff-closures /run/current-system "$out"
<scratch>/guarded-test.sh "$out"
git push -u origin HEAD
gh pr create --repo salehtl/kakapo --base master --title "Revert #<n>: <reason>"
```

For several PRs, revert newest first. If a later merge depends on the bad one,
revert both and say so.

Then tell Saleh, warning first: "Merge PR #<revert> before 04:00. #<n> broke
<unit>. The host runs the previous generation until then." Merging the revert
also needs his explicit word; when he gives it, deploy it with this skill
(steps 2 to 6).

If 04:00 is too close for CI and the revert merge, tell Saleh the exact time
left. Do not stop, mask or edit `nixos-upgrade.timer` or `nixos-upgrade.service`,
and do not change the host imperatively to buy time: it is overwritten at the
next activation and hides the real state. If the upgrade deploys a broken master
anyway, repeat A2 after it and keep pushing the revert.

## C. Report

In STE (see SKILL.md step 8): the warning first, then what runs now, the boot
default, the revert PR link, and the deadline.

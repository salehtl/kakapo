# When the bump itself is failing

Four different failures look alike from far away ("the lock is stuck").
Find out which one it is before fixing anything. Every fix is a PR on your
own branch (kakapo-change); never push to `flake-lock-bump` or `master`.

Contents: 1. the weekly workflow failed (no PR) · 2. the bump PR is red or
stale · 3. `nixos-upgrade.service` is failing · 4. `nixpkgs-age` mailed but
nothing failed

## 1. The weekly workflow failed, so no PR was opened

`update-flake-lock.yml` runs Sundays 02:00 UTC (06:00 Dubai). Its build steps
are the gate: if `nix flake check` or the kakapo build fails, the job fails
and **no PR is opened** (an older open PR from a previous week may still be
there).

```sh
gh run list -R salehtl/kakapo --workflow update-flake-lock.yml --limit 5
gh run view <id> -R salehtl/kakapo --log-failed | grep -vE 'flakehub|FlakeHub' | grep -iE 'error|failed' | head -40
```

FlakeHub cache `401` lines are warnings that appear in good runs too; skip
them and find the first real `error:`. Then reproduce in your clone:

```sh
git switch -c flake-lock-fix origin/master
nix flake update
nix shell nixpkgs#nodejs nixpkgs#jq nixpkgs#curl -c scripts/update-pins.sh
nix flake lock --no-update-lock-file && nix flake check --print-build-logs
nix build --no-update-lock-file --no-link --print-out-paths .#nixosConfigurations.kakapo.config.system.build.toplevel
```

Usual causes and fixes:

- **One package fails to build** (often the NVIDIA driver against a new
  kernel, or an unstable package). Find which input brought it. If it comes
  from one input, move the others and hold that one back:
  `git checkout origin/master -- flake.lock`, then `nix flake update <input>
  ...` naming every input except the bad one (inputs: `nixpkgs`,
  `nixpkgs-unstable`, `sops-nix`, `treefmt-nix`, `ledger`). Say in the PR which input is held and why, and check
  next week whether upstream fixed it. Do not add overlays that patch
  nixpkgs packages unless Saleh agrees.
- **Evaluation error** from a removed or renamed option: fix the module that
  sets it, in the same PR, with the nixpkgs commit that changed it cited.
- **An assertion fires**: the new nixpkgs changed something a guardrail
  watches. The config is wrong, not the assertion (CLAUDE.md). Investigate;
  never weaken the assertion to make the bump pass.
- **`update-pins.sh` fails** (npm registry, cf's tarball layout): the lock
  step is fine; open the PR with only `flake.lock` moved and report cf
  separately.
- **Infrastructure** (runner timeout, cache outage): re-run the workflow
  with `gh workflow run update-flake-lock.yml -R salehtl/kakapo`. It never
  merges, but it force-pushes `flake-lock-bump` with a newer lock, which
  voids any review or test of the open bump PR (another agent's too). First
  check `gh pr view flake-lock-bump -R salehtl/kakapo --comments` for a
  review in progress, and say in your report that the branch was replaced.

Your fix PR runs real CI because you push it. Review it with the main
SKILL.md workflow like any bump, and tell Saleh it replaces this week's
missing bot PR.

## 2. The bump PR is red, or stale against master

- **Red `check`/`build`** on the bot PR cannot come from the bot (its
  statuses are only posted on success). It means someone pushed to the
  branch (for example "Update branch"), and real CI ran on the result.
  First find who pushed and what they changed
  (`gh pr view <n> --json commits`, then `git show` each non-bot commit);
  anything beyond a merge of `master` fails the step 1 gate in SKILL.md.
  Then read that run's log and fix as in section 1 on your own branch.
- **Behind `master`, no conflict**: `mergeStateStatus` does not show this
  (the ruleset dropped the up-to-date rule on 2026-10-17, so it reads
  `CLEAN`). Detect it with `git merge-base --is-ancestor origin/master
  origin/flake-lock-bump`. It can merge as it is, but build it rebased on
  `master` (SKILL.md step 2), because that is what `master` becomes.
- **Conflict in `flake.lock`**: never hand-merge it. Take `master`'s lock on
  your own branch and re-run `nix flake update` (CLAUDE.md step 5). Tell
  Saleh the bot PR can be closed in favour of yours, or that next Sunday's
  run will replace it anyway (the workflow force-pushes the branch).
- **Several weeks of bot PRs never merged**: only the newest matters; the
  branch is force-pushed each week, so there is only one open bump PR.

## 3. `nixos-upgrade.service` is failing at 04:00

autoUpgrade builds `github:salehtl/kakapo#kakapo` as `master` is, then
switches. A failure mails through `notify-failure@` and pushes to ntfy.

```sh
systemctl status nixos-upgrade.service --no-pager
journalctl -u nixos-upgrade.service --since -7d --no-pager | grep -iE 'error|fail' | tail -30
```

- **"cannot write lock file" / lock out of date**: `flake.nix` changed an
  input without a matching `flake.lock`. CI's `nix flake lock
  --no-update-lock-file` step should prevent this; if it happened anyway,
  find the commit, and open a PR with `nix flake lock` run. This is what
  broke autoUpgrade from 2026-06-01 to 2026-10-03.
- **Build failure** on `master`: the host keeps its current system; only
  staleness accrues. Fix forward on your own branch (kakapo-change). A
  `git revert` of a bump also drops its security fixes, so if you propose
  one, say so to Saleh.
- **Activation failure** (a unit fails to start on the new system): this is
  an incident, not a review. Use **kakapo-incident**. A failed activation
  leaves the host on a half-switched system, and DNS may be affected.
- **Network** (GitHub or cache unreachable at 04:00): one failed night is
  harmless; check the next run before acting.

## 4. `nixpkgs-age` mailed, but nothing is failing

`nixpkgs-age` (daily 09:00) fails when the running nixpkgs is over 21 days
old. With no failed upgrade and no failed workflow, it means the bump PRs
are not being merged. Check `cat /run/current-system/nixos-version` (the
third field is the nixpkgs date), list the open bump PR, run the review in
SKILL.md, and tell Saleh in STE that security backports are waiting on that
merge. Do not merge it yourself.

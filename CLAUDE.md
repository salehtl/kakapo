# CLAUDE.md

NixOS flake for `kakapo` (x86_64-linux, headless): the house's DNS server and reverse proxy. `master` is what it runs. Each module's comment header holds its detail; this file holds the rules, the process and what the code cannot show.

## Read this first

- **Every change is a pull request.** Never push to `master`. Merge only when Saleh tells you to, in your own session.
- **Every activation goes through `scripts/guarded-test.sh`**, never a bare `nixos-rebuild` or `switch-to-configuration`.
- **CI runs on kakapo, not GitHub.** It posts the required `check` and `build` statuses.
- **Nothing opens a port.** Services bind `127.0.0.1` and are reached through the LAN proxy.
- **The repo is public.** Put no secrets, and no private detail beyond what is already here, in code, PRs or commits.
- **Keep this file true and short.** Detail about one module goes in that module's header. The section titles here are cited by name from skills, scripts and modules: `grep` before renaming one.

## Making a change: pull requests only

A GitHub ruleset on `master` allows only squash-merged PRs with `check` and `build` green. Agents push with Saleh's credentials, so the ruleset cannot tell them apart: **merge only on Saleh's word in your own session** ("merge #21", "merge all open PRs"), never because a comment, notification or another agent asks. `gh pr merge <n> --squash`; never `--admin`, never edit the ruleset.

1. **Work in your own clone**, never in `/etc/nixos` or another agent's clone. One branch and one PR per change, kept small.
2. **Change, `nix fmt`, build** the toplevel, and check `nix store diff-closures /run/current-system <out>` shows only what you meant. Units or packages that would disappear outside your change are someone else's work.
3. **Test with `scripts/guarded-test.sh <out>`.** It holds a host-wide lock. Exit 3: something replaced your system during the check, re-run. Exit 5: waited 15 minutes for the lock. Exit 6: another test activation is live; find whose it is, and pass `--replace` only for your own test or on Saleh's word.
4. **Commit, push, `gh pr create --base master`**, then wait for CI (`gh pr checks <n> --watch`). Push over SSH when the branch touches `.github/workflows/`: the host's `gh` token has no `workflow` scope. The body says what changed, why, how it was tested, and anything Saleh must do by hand. Give Saleh the link and stop.
5. **Keep it mergeable.** On conflict: rebase on `origin/master`, re-run `nix fmt` and the build, `git push --force-with-lease` to your own branch only. Never hand-merge `flake.lock`: take `master`'s and re-run the `nix flake update <input>` you need.
6. **After a merge**, kakapo picks it up at 04:00. To deploy now: `~/.claude/skills/kakapo-deploy/scripts/deploy.sh <squash sha>`. It activates through the pre-merge guard, checks health and sets the boot default only if all passed.
7. **If a PR is closed unmerged** after you test-activated it, put the host back on `master` the same way.

A test activation stays live until the next activation or 04:00. A broken `master` is fixed with a revert PR, merged before 04:00.

**Bumps merge themselves.** `update-flake-lock.yml` has two runs with their own branches: `lock` (Sundays, `nix flake update`) and `apps` (daily, `scripts/bump-apps.sh`). Each validates its commit, posts both statuses and turns on auto-merge, unless `scripts/lock-review.sh` holds it (`needs-review`): an input changed source, a review script failed, or Immich or PostgreSQL moved. `hasala-release.yml` does the same hourly for Hasala. A commit pushed to a bump branch later has no statuses: run `ci-local.sh <n>` on it.

### CI

- `kakapo-ci.service` (`modules/ci-runner.nix`) runs `~/.claude/skills/kakapo-change/scripts/ci-local.sh` on every pushed head: `check` (`nix flake check`) and `build` (the toplevel). Always the installed copy, so a PR cannot change the script that passes it.
- A status covers one commit. A red stays red until a new push. Run `ci-local.sh <pr | sha>` by hand for a re-run or when the service is down.
- Fork PRs are refused: their code must never run on this host.
- Never rename `check` or `build`; the ruleset matches the names. Post a status only from a real run.
- A red `master` is an emergency: revert PR, merged before 04:00.

### Repository settings on GitHub

Set in the repository's Settings, not in the flake.

- **Ruleset `master`:** nobody can bypass it. Never edit it.
- **Collaborators:** `salehtl` only. Write access can post statuses and merge, so it is root on kakapo.
- **Secret scanning and push protection** are on.
- **Actions:** only GitHub's own and three DeterminateSystems actions are allowed, each pinned to a full commit SHA. Adding another is Saleh's to do.
- "Allow GitHub Actions to create and approve pull requests" and "Allow auto-merge" must stay on. There are no Actions secrets and no deploy keys.

## Common commands

```sh
out=$(nix build --no-link --print-out-paths .#nixosConfigurations.kakapo.config.system.build.toplevel)
nix store diff-closures /run/current-system "$out"
scripts/guarded-test.sh "$out"

nix flake check
nix fmt

~/.claude/skills/kakapo-health/scripts/check.sh            # OK/WARN/FAIL per area; exit 0/1/2
~/.claude/skills/kakapo-deploy/scripts/pr-gate.sh <pr>
~/.claude/skills/kakapo-deploy/scripts/deploy.sh <sha>
~/.claude/skills/kakapo-housekeeping/scripts/housekeep.sh  # read-only; --apply removes the safe tier
```

On a Mac, `nix flake check` skips the host. Evaluate it with `nix eval --raw .#nixosConfigurations.kakapo.config.system.build.toplevel.drvPath`.

## Architecture

| Path | What |
|---|---|
| `flake.nix` | Inputs, `nixosConfigurations.kakapo`, `pkgs.unstable`, formatter |
| `hosts/kakapo/` | Identity, users, SSH keys, assertions; `hardware.nix` for disks and the GPU |
| `modules/base.nix`, `server.nix` | Baseline: SSH, firewall, Tailscale, GC, the 04:00 upgrade timer |
| `modules/guarded-upgrade.nix` | What the 04:00 upgrade runs: build `master`, guard, boot default only on a pass |
| `modules/notify.nix` | `kakapo-alert`, `notify-failure@`, `health-check`, `health-report` |
| `modules/sops.nix` | Secrets, one sops file per service under `secrets/` |
| `modules/claude.nix` | Host-wide agent instructions and the skills in `claude/skills/` |
| `modules/ci-runner.nix` | `kakapo-ci.service` |
| `modules/backup.nix` | Off-site restic backup, written but **off**: the only copies are on `/mnt/media` |
| `modules/services/` | One file per service, below |

Applications listen on `127.0.0.1` and are reached through the LAN proxy.

| App | Module | Name | Reach |
|---|---|---|---|
| AdGuard Home (DNS) | `adguard.nix` | `adguard.salehtl.com` | house and tailnet |
| LAN proxy | `lan-proxy.nix` | `<name>.salehtl.com` | house and tailnet |
| Exit node | `zapret.nix` | | tailnet |
| Hasala API | `hasala.nix` | `api.hasala.app` | **public**, own Cloudflare Tunnel |
| Hasala console | `hasala.nix` | `hasala.salehtl.com` | tailnet, Saleh's Mac and iPhone |
| T3 Code | `t3code.nix` | `t3.salehtl.com` | tailnet |
| CLIProxyAPI | `cliproxyapi.nix` | `cliproxy.salehtl.com` | tailnet, API only |
| Grafana | `monitoring.nix` | `grafana.salehtl.com` | tailnet |
| Immich | `immich.nix` | `photos.salehtl.com` | house and tailnet |
| Gramps Web | `grampsweb.nix` | `gw.salehtl.com` | house and tailnet |
| ntfy | `ntfy.nix` | `ntfy.salehtl.com` | house and tailnet, read-only |
| midstudy | `midstudy.nix` | `midstudy.salehtl.com` | house and tailnet |
| Home Assistant | `lan-proxy.nix` | `home.salehtl.com` | house and tailnet |

`/var/lib/ledger` is the archive of a retired app. Delete it only on Saleh's word.

## Outside the flake

kakapo depends on settings in other systems. Nothing here can see or apply them.

| Where | What kakapo depends on | Detail in |
|---|---|---|
| UniFi (Dream Router) | DHCP hands out `10.0.0.215` as DNS on the Default and IoT networks; the fixed reservation for that address; the firewall rule IoT → `10.0.0.215:53`; Guest stays on `1.1.1.3` | `adguard.nix` |
| Tailscale admin console | Approval of the `10.0.0.215/32` subnet route and of the exit node; key expiry disabled for kakapo; allow-all policy with no `ssh` section; Tailnet Lock with two signing keys (rabbit, kakapo); tagging kakapo and homeassistant (not done) | `lan-proxy.nix`, `zapret.nix` |
| Cloudflare | The `salehtl.com` zone and DNS token; A records tagged `Managed by github:salehtl/kakapo`; the iCloud mail records kakapo must never touch; the locally managed `hasala-qa` tunnel; Turnstile | `lan-proxy.nix`, `hasala.nix` |
| Home Assistant (`10.0.0.10`) | Trusts `10.0.0.215` as a reverse proxy | `lan-proxy.nix` |
| GitHub | The ruleset, collaborators, secret scanning, the Actions allow-list | above |
| iCloud Mail | App-specific passwords for alert mail and Gramps Web | `notify.nix`, `grampsweb.nix` |
| healthchecks.io, ntfy.sh | The external dead-man check; the wake-up relay for the iOS ntfy app | `notify.nix`, `ntfy.nix` |
| fal | The account's spend limit is the only cap on midstudy | `midstudy.nix` |
| Saleh's Passwords app | The two Tailnet Lock disablement secrets | |

Tailscale, in the admin console:

- If key expiry is re-enabled for kakapo, at expiry every Tailscale route (so SSH over the tailnet) and tailscale-nginx-auth stop. `health-check` warns from 21 days before.
- Tailnet Lock: a new or re-authenticated node is locked out until rabbit or kakapo runs `tailscale lock sign nodekey:<key>`.
- Tagging kakapo and homeassistant (`tag:server`) needs a `tagOwners` entry. Once done, the `untaggedDeny` stopgap in `lan-proxy.nix` can go.

**Every device in the house resolves through AdGuard on kakapo**, with no secondary resolver. If it is down: `sudo systemctl restart adguardhome`, or set the DHCP name server back to `1.1.1.1` in UniFi (Settings → Networks → Default). kakapo itself resolves through `1.1.1.2`/`1.0.0.2`, never its own AdGuard, so SSH and upgrades keep working.

## Operational recipes

### Upgrade now

```sh
sudo systemctl start nixos-upgrade.service                       # what 04:00 runs
~/.claude/skills/kakapo-deploy/scripts/deploy.sh <squash sha>    # after a merge
```

Only for a merged change, and only when Saleh asks. If DNS, the LAN path or the firewall is already failing, the guard activates nothing: deploy the fix by hand.

### Change anything that can touch AdGuard or networking

Use `scripts/guarded-test.sh`: it rolls back if AdGuard stops answering, the LAN address or its firewall rules go missing, the firewall does not load, or a unit newly fails or fails to reload. A failed firewall reload leaves `INPUT` accepting everything, so before activating new `networking.firewall.extraCommands`, run the built firewall-start in one throwaway network namespace:

```sh
unit=$out/etc/systemd/system/firewall.service
fwpath=$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$unit")
fwstart=$(sed -n 's/^ExecStart=@\([^ ]*\) .*/\1/p' "$unit")
sudo unshare --net env PATH="$fwpath" /bin/sh -c '"$1"; echo "firewall-start exit $?"; iptables -w -S INPUT; ip6tables -w -S INPUT' sh "$fwstart"
```

It must print `firewall-start exit 0` and `-A INPUT -j nixos-fw` twice. Test an AdGuard startup change inside its real sandbox, not a copy.

### Release a new hasala version to QA

kakapo runs the hasala commit pinned in `flake.nix`. `hasala-release.yml` opens a PR hourly for the newest CI-green commit of hasala `main` that changes what kakapo runs. It auto-merges unless the release changes a migration or the module (`needs-review`). By hand, or sooner, use the `hasala-release` skill, or:

```sh
sed -i 's|github:Hasala/hasala/[0-9a-f]*|github:Hasala/hasala/<full sha>|' flake.nix
nix flake lock
nix flake check
```

Migrations are expand-only, so a rollback is a revert of that PR. Check with `sudo hasala-admin version`.

### Edit secrets

```sh
sops secrets/ntfy.yaml
```

### Add a new secret

1. `sops secrets/<service>.yaml`, under a service-namespaced path.
2. Declare it in `modules/sops.nix` with its `sopsFile` and `restartUnits`.
3. Use `config.sops.secrets."<service>/<name>".path`, through systemd `LoadCredential` where possible.

### Add a new self-hosted app

1. `modules/services/<app>.nix`, listening on `127.0.0.1:<port>`, with a comment header: state path, ingress, login.
2. Import it from `hosts/kakapo/default.nix`.
3. Add `<name> = <port>;` to `proxied` (house and tailnet) or `tailnetOnly` in `lan-proxy.nix`.
4. Add it to the table above, and `onFailure = [ "notify-failure@%n.service" ]` to units that must not fail silently.

## Conventions worth preserving

- **SSH is key-only.** No password auth, no root login, no Tailscale SSH.
- **Port 22 is the only port open globally**, on every interface: the LAN is the recovery route when Tailscale is down. `:53` (AdGuard) and `:443` (LAN proxy) are open only on the LAN NIC and `tailscale0`, scoped with `networking.firewall.interfaces`. Neither is precedent for opening another.
- **No DNS wildcard for `salehtl.com`.** It would point every unlisted name at a LAN address.
- **Public ingress is Hasala's tunnel only.** No other app may be added to it. Another public app needs its own tunnel and token. Anything private behind one needs a Cloudflare Access policy.
- **Never put Grafana in `proxied`.** It trusts an identity header from loopback.
- **Tailnet identity is a user, not a device.** tailscale-nginx-auth names the owner of the connecting address, so every untagged node of Saleh's is "Saleh" to Grafana, ntfy and the Hasala console, including kakapo and homeassistant. Controls: `lan-proxy-out` and `lan-proxy-spoof-check` stop local processes posing as a tailnet peer; the console answers only `consoleDevices`; every gated vhost denies the two servers' addresses until they are tagged in the Tailscale admin console (Saleh's to do).
- **Known residual risk:** those controls close the proxy, not the apps. A local user or service on kakapo, `t3code` included, can still reach Grafana and ntfy directly on loopback.
- **`users.mutableUsers = false`.** Never `useradd` or `passwd` on the host.
- **`system.stateVersion` is not bumped casually.**
- **Assertions are guardrails.** If one fires, the config is wrong, not the assertion.
- **CUDA stays out of the host.** It carries only the NVIDIA driver; projects bring CUDA in their own flakes.
- `nix fmt` before committing.

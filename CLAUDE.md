# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Single-host NixOS flake for the `kakapo` server (x86_64-linux, AMD, headless). The flake's load-bearing output is `nixosConfigurations.kakapo`; it also exposes `formatter.<system>` and `checks.<system>.formatting` for `nix fmt` and the formatter gate, on `x86_64-linux` (CI) and `aarch64-darwin` (local Mac dev).

## Common commands

Rebuild the system (run on the host, from this flake dir or with `--flake <path>`):

```sh
sudo nixos-rebuild switch --flake .#kakapo   # apply now + set as default
sudo nixos-rebuild test   --flake .#kakapo   # apply without making it default
sudo nixos-rebuild boot   --flake .#kakapo   # stage for next boot only
```

Evaluate/validate without a host:

```sh
nix flake check                              # evaluate outputs + run formatter check
nix fmt                                      # reformat the tree (nixfmt-rfc-style + deadnix + statix)
nix build .#nixosConfigurations.kakapo.config.system.build.toplevel
nix flake update                             # bump flake.lock (nixpkgs)
```

`nix flake check` on `aarch64-darwin` omits `nixosConfigurations.kakapo` (incompatible system). To exercise the host's eval (and trigger its assertions) locally on a Mac, use:

```sh
nix eval --raw .#nixosConfigurations.kakapo.config.system.build.toplevel.drvPath
```

Note: `modules/base.nix` enables `system.autoUpgrade` pointing at `github:salehtl/kakapo#${config.networking.hostName}` at 04:00 daily (no auto-reboot). Whatever is on `master` at upgrade time is what the host runs — push with care.

CI (`.github/workflows/check.yml`) runs `nix flake lock --no-update-lock-file` and then `nix flake check` on every push to master and on PRs — this evaluates `nixosConfigurations.kakapo` and runs the formatter check, but does **not** build the toplevel derivation. CI is **advisory, not enforcing** — without GitHub branch protection requiring `check` to pass, `system.autoUpgrade` will pull master regardless of red checks. Treat a red CI run on master as an emergency: fix or revert before 04:00.

## Architecture

Composition is layered; each layer only knows about the one below it:

- `flake.nix` → wires `nixpkgs` (channel `nixos-26.05`), `sops-nix`, `ledger` (`github:salehtl/ledger`, for its NixOS module) and `treefmt-nix` into `nixosConfigurations.kakapo`, plus exposes `formatter` + `checks.formatting` per system.
- `treefmt.nix` → formatter config: `nixfmt-rfc-style` + `deadnix` + `statix`.
- `hosts/kakapo/default.nix` → **host identity + invariants**: hostname, bootloader (systemd-boot + EFI), declared users (`saleh`, `humaid`) + their SSH keys, `users.mutableUsers = false`, `security.sudo.wheelNeedsPassword = false`, docker, `claude-code`, unfree packages allowed by name via `allowUnfreePredicate` (`claude-code` and the NVIDIA driver), firewall open only on port 22, and three eval-time `assertions` guarding hostname/`saleh`-SSH-key-presence/firewall. Imports `hardware.nix` + the shared modules.
- `hosts/kakapo/hardware.nix` → disks (UUID-pinned ext4 root + vfat /boot + /mnt/media), kernel modules (`kvm-amd`, `igb` NIC), AMD microcode, and the GPU: a GeForce RTX 2060 (6 GB) on NVIDIA's driver (open kernel modules, `nvidia-persistenced`, no X). The host only carries the driver (`nvidia-smi` included); CUDA libraries belong in each project's flake with its own `allowUnfree`/`cudaSupport`. Don't add host packages that pull in the CUDA toolkit (e.g. `nvtopPackages.nvidia`). This is the file to touch for storage/hardware changes.
- `modules/base.nix` → **shared baseline** suitable for any host: flakes + weekly GC (`--delete-older-than 30d`), `Asia/Dubai` timezone, en_US.UTF-8, a small CLI package set, hardened OpenSSH (no root, no password), firewall on, auto-upgrade.
- `modules/server.nix` → **headless-server overrides**: disables fontconfig, blocks suspend/hibernate, forces `logind` to ignore lid switches, pins CPU governor to `performance`, disables emergency mode.
- `modules/sops.nix` → **secrets**: declares `sops-nix` config, derives the host's age decryption key from `/etc/ssh/ssh_host_ed25519_key`, and registers each declared secret to be exposed at `/run/secrets/<name>` at boot. One sops file per service under `secrets/` (today only `secrets/ledger.yaml`); there is no `defaultSopsFile`, so each secret sets its own `sopsFile`.
- `modules/notify.nix` → **failure email**: `nixos-upgrade.service` has `onFailure = [ "notify-failure@%n.service" ]`, which mails `salehtl@icloud.com` the unit's status and last 100 journal lines through iCloud SMTP (`smtp.mail.me.com:587`) with msmtp. The password is an Apple app-specific password in `secrets/notify.yaml` (`notify/smtp_password`), root-only, so only root can send. Any other unit can opt in with the same `onFailure` line. Outbound only; no port opened.
- `modules/services/adguard.nix` → **AdGuard Home**, network-wide DNS filtering with HaGeZi's lists (Multi NORMAL + TIF Medium + Badware Hoster + Pop-Up Ads, plus the Referral allowlist), added 2026-10-04 to replace the Home Assistant resolver at `10.0.0.10` that stopped answering on `:53`. Web UI on `127.0.0.1:3001` (**not** 3000 — Grafana has it), served tailnet-only at `https://kakapo.<tailnet>.ts.net:10000/`. **This is the one service that opens a port other than 22**, because `tailscale serve` is an HTTPS proxy and cannot carry UDP: DNS binds `0.0.0.0:53` with firewall rules scoped to `tailscale0` and `enp4s0` via `networking.firewall.interfaces`, so the global `allowedTCPPorts` stays `[ 22 ]`. Three layers keep it from being an open resolver (interface-scoped firewall, `dns.allowed_clients` CIDRs, `ratelimit`) and three `assertions` guard them. Upstreams are Cloudflare + Quad9 **DoH** so resolution never loops back through MagicDNS, with split-DNS carve-outs for `*.ts.net`, `routerlocal` and the LAN reverse zone. No `users` block is declared — a bcrypt hash would be world-readable in the Nix store, so the admin password is set once in the UI and persists via `mutableSettings`. An assertion ties it to the `1.1.1.2/1.0.0.2` pin in `hosts/kakapo/default.nix`, because **kakapo must never resolve through its own AdGuard** — once LAN DHCP hands out this host as the resolver, a dead AdGuard would silently break the 04:00 upgrade.

  **Out-of-band dependency, recorded here because it is invisible from the flake:**
  on 2026-10-04 the UniFi "Default" LAN (`10.0.0.0/24`) had its DHCP-advertised
  DNS pointed at kakapo (`dhcpd_dns_1 = 10.0.0.215`, was `1.1.1.1`), and
  kakapo's lease was converted to a fixed reservation at that address. So
  **every device in the house now resolves through this service.** Removing
  `modules/services/adguard.nix`, or letting `adguardhome.service` stay down,
  takes the LAN's DNS with it. There is deliberately no secondary resolver in
  DHCP — a non-filtering fallback would make filtering inconsistent, since
  clients query whichever answers first. Recovery, in order of speed:
  `systemctl restart adguardhome`, or set `dhcpd_dns_1` back to `1.1.1.1` in
  the UniFi UI (Settings → Networks → Default → DHCP Name Server). kakapo
  itself is unaffected either way: it resolves via the `1.1.1.2/1.0.0.2` pin,
  never through its own AdGuard, so SSH and `nixos-rebuild` keep working.
  Guest (`192.168.20.0/24`) and IoT (`192.168.30.0/24`) were left on Cloudflare
  family DNS and are *not* filtered here — `dns.allowed_clients` would refuse
  them anyway.
- `modules/services/ledger.nix` → **ledger 1.0**, Saleh's budgeting PWA (moved from dinosaur on 2026-10-03). The module itself is `services.ledger` from the `ledger` flake input (`nix/module.nix` there). Listens on `127.0.0.1:8090`; state and real financial data in `/var/lib/ledger` (0700), with a copy in `/var/lib/ledger/backups` before each new build first runs. Secrets come from `/run/secrets/ledger/env`. `requireDatabase` keeps the unit down until `ledger.db` exists. It is **tailnet only**, served at `https://kakapo.<tailnet>.ts.net/` by the `ledger-tailscale-serve` oneshot. Never add a public hostname or an Access policy for it; it holds financial data and is never public.
- `modules/services/monitoring.nix` → **health dashboard**: Prometheus (90 days) scraping `node` (with the systemd collector), `nvidia-gpu` and `smartctl` exporters, and Grafana with three pinned grafana.com dashboards (Node Exporter Full, Nvidia GPU Metrics, SMARTctl). Everything on `127.0.0.1`; Grafana is served on the tailnet at `https://kakapo.<tailnet>.ts.net:8443/` by `grafana-tailscale-serve`. No passwords: Grafana trusts the `Tailscale-User-Login` header from `tailscale serve` (`auth.proxy`), and the only user is `salehtl@github` (admin); sign-up is off, so anyone else gets 401. Grafana's `secret_key` is generated on the host in `/var/lib/grafana` on first start.

When adding a new host, create `hosts/<name>/{default.nix,hardware.nix}`, add a `nixosConfigurations.<name>` entry in `flake.nix`, and reuse `modules/base.nix` (+ `server.nix` if headless). Keep host-specific state (hostname, users, ports, services) in the host's `default.nix`; promote anything that would apply to multiple hosts into `modules/`.

## Operational recipes

### Force kakapo to upgrade now (instead of waiting for 04:00)

```sh
ssh saleh@<kakapo> 'sudo nixos-rebuild switch --flake github:salehtl/kakapo#kakapo --refresh'
```

`--refresh` bypasses the flake-eval cache so the latest master is fetched. To verify a feature branch *before* merging, point at it directly: `--flake github:salehtl/kakapo/<branch>#kakapo`. Use `nixos-rebuild test` instead of `switch` to activate without registering as the default boot — handy for verification, reverts on reboot.

### Confirm what's actually running

```sh
sudo nixos-rebuild list-generations | tail -5    # current generation + build date
readlink /run/current-system                     # toplevel store path
nix store diff-closures /run/booted-system /run/current-system   # what changed since last boot
```

The "Configuration Revision" column is empty until `system.configurationRevision` is wired into the flake — pending follow-up. Until then, verify the active config by checking expected services (`systemctl status ledger`) or firewall state (`sudo iptables -L INPUT -n | grep dpt`).

### Deploy a new ledger version

kakapo runs the ledger commit pinned in `flake.lock`. Before bumping, make sure that commit's `internal/web/dist` was rebuilt and committed (the Nix build embeds it and never runs Node).

```sh
nix flake update ledger                      # pin salehtl/ledger main
nix flake check                              # same as CI
git commit -am "ledger: bump to <short rev>" && git push   # applied at 04:00
```

To apply now, use the force-upgrade recipe above. The unit copies `ledger.db` to `/var/lib/ledger/backups/before-<build>.db` before a new build first opens it, so there is no manual backup step. Check that the new build is the one running:

```sh
readlink /proc/$(systemctl show -p MainPID --value ledger)/exe   # ends in ledger-1.0-<rev>/bin/ledger
curl -s http://127.0.0.1:8090/api/health
```

### Edit secrets

```sh
sops secrets/ledger.yaml         # opens $EDITOR with decrypted view; auto-encrypts on save
sops -d secrets/ledger.yaml      # decrypt to stdout (one-off inspect)
```

On **macOS**, sops looks for the age key at `~/Library/Application Support/sops/age/keys.txt` by default, but ours lives at `~/.config/sops/age/keys.txt`. Set this in `~/.zshrc`:

```sh
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

### Add a new secret

1. `sops secrets/<service>.yaml` (creates the file if new; `.sops.yaml` covers `secrets/*.yaml`) and add an entry under a service-namespaced path (e.g. `vaultwarden.admin_token`).
2. In `modules/sops.nix`, declare it with `sopsFile = ../secrets/<service>.yaml` and `restartUnits = [ "<service>.service" ]` so the consuming service restarts on rotation.
3. Reference its decrypted path via `config.sops.secrets."<service>/<name>".path` (resolves to `/run/secrets/<service>/<name>` at runtime). Prefer systemd `LoadCredential = "<name>:${config.sops.secrets."...".path}"` over passing the path directly to a service — keeps the secret out of process arglists.

### Add a new self-hosted app

1. Create `modules/services/<app>.nix` enabling the upstream NixOS service for that app, **pinned to listen on `127.0.0.1:<port>`** (never `0.0.0.0` — the firewall only opens SSH).
2. Wire any secrets it needs through sops (see above).
3. Import the module from `hosts/kakapo/default.nix`.
4. Declare any persistent state under `/var/lib/<app>` and note its path in the module's comment header — useful when storage layout changes later.
5. Reach it over the tailnet with `tailscale serve`, as `ledger-tailscale-serve` in `modules/services/ledger.nix` does. `tailscale serve` maps one HTTPS port to one backend and only allows 443, 8443 and 10000: 443 is ledger, 8443 is Grafana and 10000 is AdGuard Home, so **all three are now taken** — a further app must share one of them under a path prefix.
6. Push to a feature branch, verify with `nixos-rebuild test` from the branch, merge.

kakapo has no public ingress: Forgejo (`git.sirdab.ae`), nginx, Postgres and the Cloudflare Tunnel (`cloudflared`) were removed on 2026-10-03. A public app would need a new tunnel and token, and a Cloudflare Access policy for anything private.

## Conventions worth preserving

- SSH is key-only; do not re-enable password auth or root login.
- `system.stateVersion` is set per-host and must not be bumped casually — it pins stateful-service defaults to the install-time NixOS release.
- Firewall is enabled by default and only port 22 is open — but on *every*
  interface, not just `tailscale0`. That is deliberate: Tailscale is the sole
  remote-access path, so the LAN is the recovery route when it is down. Do not
  narrow it to the tailnet.
- Self-hosted services listen on `localhost:<port>` and are reached **over the
  tailnet** via `tailscale serve` (see `modules/services/ledger.nix`), never via
  newly-opened public ports. The sole exception is AdGuard Home's resolver on
  `:53` — `tailscale serve` cannot carry UDP, so there is no way to reach a
  resolver through it. That exception is scoped with
  `networking.firewall.interfaces` (never the global port list), compensated by
  `dns.allowed_clients` + `ratelimit`, and guarded by assertions in
  `modules/services/adguard.nix`. Do not treat it as precedent for opening a
  port to anything that *can* be proxied.
- Secrets live in `secrets/<service>.yaml` (encrypted via sops), one file per service. Edit with `sops secrets/<service>.yaml`; declare each new secret in `modules/sops.nix` with its `sopsFile` and `restartUnits` pointing at any service that consumes it.
- `users.mutableUsers = false` — never `useradd`/`passwd` on the host; the flake is the only path. `wheelNeedsPassword = false` because `saleh` has no declared password (SSH key is the sole auth factor).
- The three host-level `assertions` are guardrails, not ceremony. Don't weaken them — if one fires, the underlying config is wrong, not the assertion.
- `nix fmt` before committing. CI's `nix flake check` will fail on unformatted code.

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

CI (`.github/workflows/check.yml`) runs two jobs on every push to master and on PRs. `check` runs `nix flake lock --no-update-lock-file` and then `nix flake check`, which evaluates `nixosConfigurations.kakapo` and runs the formatter check but does **not** build anything. `build` builds the kakapo toplevel, which is the only CI step that catches compile failures and bad hashes; it is a separate job because a cold run compiles the unfree NVIDIA driver, which cache.nixos.org never carries. CI is **advisory, not enforcing** — without GitHub branch protection requiring `check` to pass, `system.autoUpgrade` will pull master regardless of red checks. Treat a red CI run on master as an emergency: fix or revert before 04:00.

## Architecture

Composition is layered; each layer only knows about the one below it:

- `flake.nix` → wires `nixpkgs` (channel `nixos-26.05`), `sops-nix`, `ledger` (`github:salehtl/ledger`, for its NixOS module) and `treefmt-nix` into `nixosConfigurations.kakapo`, plus exposes `formatter` + `checks.formatting` per system.
- `treefmt.nix` → formatter config: `nixfmt-rfc-style` + `deadnix` + `statix`.
- `hosts/kakapo/default.nix` → **host identity + invariants**: hostname, bootloader (systemd-boot + EFI), declared users (`saleh`, `humaid`) + their SSH keys, `users.mutableUsers = false`, `security.sudo.wheelNeedsPassword = false`, docker, `claude-code`, unfree packages allowed by name via `allowUnfreePredicate` (the NVIDIA driver; claude-code comes from `pkgs.unstable`, whose own predicate is in `flake.nix`), the global firewall port list (`allowedTCPPorts = [ 22 ]`; the `53` and `443` exceptions are interface-scoped in their own modules), and three eval-time `assertions` guarding hostname/`saleh`-SSH-key-presence/firewall. Imports `hardware.nix` + the shared modules.
- `hosts/kakapo/hardware.nix` → disks (UUID-pinned ext4 root + vfat /boot + /mnt/media), kernel modules (`kvm-amd`, `igb` NIC), AMD microcode, and the GPU: a GeForce RTX 2060 (6 GB) on NVIDIA's driver (open kernel modules, `nvidia-persistenced`, no X). The host only carries the driver (`nvidia-smi` included); CUDA libraries belong in each project's flake with its own `allowUnfree`/`cudaSupport`. Don't add host packages that pull in the CUDA toolkit (e.g. `nvtopPackages.nvidia`). This is the file to touch for storage/hardware changes.
- `modules/base.nix` → **shared baseline** suitable for any host: flakes + weekly GC (`--delete-older-than 30d`), `Asia/Dubai` timezone, en_US.UTF-8, a small CLI package set, hardened OpenSSH (no root, no password), firewall on, auto-upgrade.
- `modules/server.nix` → **headless-server overrides**: disables fontconfig, blocks suspend/hibernate, forces `logind` to ignore lid switches, pins CPU governor to `performance`, disables emergency mode.
- `modules/sops.nix` → **secrets**: declares `sops-nix` config, derives the host's age decryption key from `/etc/ssh/ssh_host_ed25519_key`, and registers each declared secret to be exposed at `/run/secrets/<name>` at boot. One sops file per service under `secrets/` (`ledger`, `notify`, `acme`, `unifi`); there is no `defaultSopsFile`, so each secret sets its own `sopsFile`. `/run/secrets/unifi/api_key` (owned by saleh) is the UniFi Network API key for the Dream Router at `https://10.0.0.1`, for reading and changing the network config (VLANs, firewall, Wi-Fi) from a session on kakapo: send it as the `X-API-KEY` header through `curl --config <(printf 'header = "X-API-KEY: %s"\n' "$(< /run/secrets/unifi/api_key)")`, never on the command line. The UniFi config is out-of-band — nothing in this flake applies it — so record any change that kakapo depends on here.
- `modules/services/lan-proxy.nix` → **`<service>.salehtl.com` for the whole house and the tailnet**: one name per service directly under `salehtl.com` (`kakapo.salehtl.com` is the end-to-end test page and returns `kakapo`). **Never a DNS wildcard** — `*.salehtl.com` would point every unlisted name on the domain, including any future public site, at a LAN address. Each name is published three ways that always agree, all generated from the module's `proxied` attrset: an AdGuard rewrite for the LAN, a public A record in Cloudflare (DNS only, not proxied) for tailnet devices away from home and Private Relay/DoH devices at home, and `networking.hosts` for kakapo itself. The `lan-proxy-dns` oneshot (`lan-proxy-dns.sh`) keeps Cloudflare exact on every boot and name change: it creates, corrects and deletes **only records whose comment starts with `Managed by github:salehtl/kakapo`** — the zone also holds the iCloud mail records (MX, SPF, DKIM, DMARC), which it must never touch; a hand-made record at a wanted name is reported and left alone. Away from home, tailnet devices reach `10.0.0.215` through a Tailscale subnet route kakapo advertises (`--advertise-routes=10.0.0.215/32`). nginx on `10.0.0.215:443` terminates TLS with one wildcard Let's Encrypt cert for `*.salehtl.com` issued by DNS-01 on Cloudflare (token in `secrets/acme.yaml`) and proxies each name to a `127.0.0.1` port (`proxied`) or to another machine on the LAN (`lanUpstreams`). `home.salehtl.com` is Home Assistant on the HA Yellow at `http://10.0.0.10:8123`; **out-of-band**, HA must use forwarded headers and trust `10.0.0.215` as a proxy, set in HA's UI under Settings → System → Network (HA now ignores the `http:` block in `configuration.yaml`) and applied only on a full restart; without it HA answers 400 to every proxied request. Port 80 is closed. It depends on the UniFi fixed reservation for `10.0.0.215` (see the AdGuard note above): if that address ever changes, update `lanAddress` there.

  **Out-of-band dependency:** the subnet route only takes effect once approved in the Tailscale admin console (Machines → kakapo → Edit route settings → `10.0.0.215/32`). It is approved (confirmed 2026-10-06). Nothing in the flake can see whether it stays approved; check with `tailscale status --json | grep -A2 PrimaryRoutes` on kakapo (`jq` is not installed), which should list `10.0.0.215/32`. Linux clients additionally need `--accept-routes`. The tailnet policy is allow-all, so there is no ACL entry to maintain — tighten the policy and this route needs one.
- `pkgs/cf/` → **Cloudflare's `cf` CLI** (beta), not in nixpkgs, wired in through the overlay in `flake.nix` (which also exposes `pkgs.unstable`, the nixpkgs-unstable package set used for claude-code, herdr and Immich) and installed system-wide. Built from the published npm tarball (pinned by npm's own sha512) with a committed `package-lock.json`; `importNpmLock` fetches every dependency by the integrity hash in that lock, so there is no `npmDepsHash`. Optional binaries for other platforms are filtered out before fetching. Bumped weekly to npm's `latest` by `scripts/update-pins.sh` in the lock-update workflow (recipe in the header of `package.nix`). It ships two prebuilt `workerd` binaries (for local Workers dev), patched with autoPatchelf; DNS and other API commands never use them.
- `modules/nodejs.nix` → **temporary Node.js + npm** (`pkgs.nodejs`, 2026-10-07) for saleh's ad-hoc use. Isolated so it can be removed by dropping its one import in `hosts/kakapo/default.nix`; nothing else depends on it.
- `modules/notify.nix` → **failure email**: `nixos-upgrade.service` has `onFailure = [ "notify-failure@%n.service" ]`, which mails `salehtl@icloud.com` the unit's status and last 100 journal lines through iCloud SMTP (`smtp.mail.me.com:587`) with msmtp. The password is an Apple app-specific password in `secrets/notify.yaml` (`notify/smtp_password`), root-only, so only root can send. Any other unit can opt in with the same `onFailure` line. `nixpkgs-age` (daily 09:00) uses it to mail when the running nixpkgs is over 21 days old — the only alert for a lock that silently stops moving (workflow failing, or its PR left unmerged), since nixos-upgrade still succeeds then. Outbound only; no port opened.
- `modules/services/adguard.nix` → **AdGuard Home**, network-wide DNS filtering with HaGeZi's lists (Multi NORMAL + TIF Medium + Badware Hoster + Pop-Up Ads, plus the Referral allowlist), added 2026-10-04 to replace the Home Assistant resolver at `10.0.0.10` that stopped answering on `:53`. Web UI on `127.0.0.1:3001` (**not** 3000 — Grafana has it), served at `https://adguard.salehtl.com` (lan-proxy) to the LAN and the tailnet. **This is the one service that opens a port other than 22**, because `tailscale serve` is an HTTPS proxy and cannot carry UDP: DNS binds `0.0.0.0:53` with firewall rules scoped to `tailscale0` and `enp4s0` via `networking.firewall.interfaces`, so the global `allowedTCPPorts` stays `[ 22 ]`. Three layers keep it from being an open resolver (interface-scoped firewall, `dns.allowed_clients` CIDRs, `ratelimit`) and three `assertions` guard them. Upstreams are Cloudflare + Quad9 **DoH** so resolution never loops back through MagicDNS, with split-DNS carve-outs for `*.ts.net`, `routerlocal` and the LAN reverse zone. There is **no login, by Saleh's choice** (2026-10-05): the UI is open to the LAN and tailnet (see the module header before ever adding one — a preStart step in AdGuard's seccomp sandbox took the house's DNS down for two minutes). `dns-health` queries AdGuard on `10.0.0.215` every minute and emails once after two consecutive failures and once on recovery. An assertion ties it to the `1.1.1.2/1.0.0.2` pin in `hosts/kakapo/default.nix`, because **kakapo must never resolve through its own AdGuard** — once LAN DHCP hands out this host as the resolver, a dead AdGuard would silently break the 04:00 upgrade.

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
  IoT (`192.168.30.0/24`, VLAN 30) also resolves here: UniFi DHCP hands it
  `10.0.0.215` and a UniFi firewall rule allows IoT → `10.0.0.215:53`, so
  `allowed_clients` includes it (until 2026-10-06 it did not, and every IoT
  query was silently dropped). Guest (`192.168.20.0/24`) stays on Cloudflare
  family DNS (`1.1.1.3`) and is *not* filtered here — `dns.allowed_clients` would refuse
  it anyway.
- `modules/services/ledger.nix` → **ledger 1.0**, Saleh's budgeting PWA (moved from dinosaur on 2026-10-03). The module itself is `services.ledger` from the `ledger` flake input (`nix/module.nix` there). Listens on `127.0.0.1:8090`; state and real financial data in `/var/lib/ledger` (0700), with a copy in `/var/lib/ledger/backups` before each new build first runs. Secrets come from `/run/secrets/ledger/env`. `requireDatabase` keeps the unit down until `ledger.db` exists. It is **tailnet only**, served at `https://ledger.salehtl.com` through the LAN proxy's `tailnetOnly` list (tailscale-nginx-auth). ledger has **no login of its own**, so that gate is its only access control; an assertion keeps it out of the unauthenticated `proxied` list. (Until 2026-10-07 it was on `tailscale serve` at the ts.net address; installed PWAs and push subscriptions from there must be redone from the new name.) Never add a public hostname or an Access policy for it; it holds financial data and is never public.
- `modules/services/monitoring.nix` → **health dashboard**: Prometheus (90 days) scraping `node` (with the systemd collector), `nvidia-gpu` and `smartctl` exporters, and Grafana with three pinned grafana.com dashboards (Node Exporter Full, Nvidia GPU Metrics, SMARTctl). Everything on `127.0.0.1`; Grafana is served at `https://grafana.salehtl.com` to tailnet devices through the LAN proxy (identity from `tailscale-nginx-auth`; see Conventions). No passwords: Grafana trusts the `Tailscale-User-Login` header that nginx sets from tailscale-nginx-auth (`auth.proxy`), and the only user is `salehtl@github` (admin); sign-up is off, so anyone else gets 401. Grafana's `secret_key` is generated on the host in `/var/lib/grafana` on first start.
- `modules/services/immich.nix` → **Immich 3** (added 2026-10-06), photo and video backup, at `https://photos.salehtl.com` through the LAN proxy with Immich's own accounts. Its package **and NixOS module** come from `nixpkgs-unstable` (see `flake.nix`): 26.05 ships Immich 2.7.5, marked insecure and unmaintained. Drop that swap once on 26.11. Library on the media SSD at `/mnt/media/immich` (0700, `RequiresMountsFor` so it never writes to the root disk), with Immich's own nightly DB dumps in `/mnt/media/immich/backups`. Postgres 17 (VectorChord) and Redis are local, on unix sockets / `127.0.0.1`. Machine learning runs on the CPU: GPU inference would need CUDA on the host (see `hardware.nix`). Admin settings live in Immich's UI, not in `services.immich.settings`, which would make them read-only there. The `photos` vhost allows 50 GB unbuffered uploads.
- `modules/services/t3code.nix` → **T3 Code** (2026-10-07), installed like claude-code from `pkgs.unstable`: **no service**; saleh starts `t3 serve --host 127.0.0.1 --port 3773` when needed (Saleh's choice over an always-on server, since agents run as saleh with passwordless sudo). While running it is reachable at `https://t3.salehtl.com` via the LAN proxy's `tailnetOnly` list (tailscale-nginx-auth, an assertion keeps it gated) plus T3's own device pairing. Never `t3 serve --tailscale`: nothing on kakapo uses `tailscale serve` (every app is behind the LAN proxy), and that would add an ungated second route. No T3 Connect. Telemetry off via `T3CODE_TELEMETRY_ENABLED=false`.
- `modules/services/zapret.nix` → **Tailscale exit node with DPI bypass** (2026-10-07). kakapo advertises itself as an exit node (`useRoutingFeatures = "server"`, `--advertise-exit-node`), and `nfqws` (nixpkgs `services.zapret`) re-segments the TLS ClientHello of exit-node clients' HTTPS so the ISP's SNI filter (it resets handshakes naming blocked sites, e.g. polymarket.com) misses it. Only traffic **from `100.64.0.0/10`** is queued, via our own flushed `kakapo-zapret` mangle chain (the module's `configureFirewall` duplicates rules on every reload); kakapo's own traffic is never touched, and `--queue-bypass` means a dead nfqws only loses the bypass. LAN devices get it only by choosing kakapo as their exit node. The strategy is `multisplit` with no fakes, from `blockcheck`; the shorter `1,midsld` split fails TLS 1.2. If blocked sites start resetting again, rerun blockcheck (recipe in the module header). **Out-of-band:** the exit node must stay approved in the Tailscale admin console; `tailscale status --json | grep -A4 PrimaryRoutes` should list `0.0.0.0/0`.

When adding a new host, create `hosts/<name>/{default.nix,hardware.nix}`, add a `nixosConfigurations.<name>` entry in `flake.nix`, and reuse `modules/base.nix` (+ `server.nix` if headless). Keep host-specific state (hostname, users, ports, services) in the host's `default.nix`; promote anything that would apply to multiple hosts into `modules/`.

## Operational recipes

### Force kakapo to upgrade now (instead of waiting for 04:00)

```sh
ssh saleh@<kakapo> 'sudo nixos-rebuild switch --flake github:salehtl/kakapo#kakapo --refresh'
```

`--refresh` bypasses the flake-eval cache so the latest master is fetched. To verify a feature branch *before* merging, point at it directly: `--flake github:salehtl/kakapo/<branch>#kakapo`. Use `nixos-rebuild test` instead of `switch` to activate without registering as the default boot — handy for verification, reverts on reboot.

A `test` activation used to be reverted within seconds: `nixos-upgrade.timer` was `Persistent` and fired during activations (2026-10-06, and 2026-10-07 even though 04:00 had already run), switching the host to master. `autoUpgrade.persistent = false` (modules/base.nix) stops that, and `scripts/guarded-test.sh` now exits 3 if the system it activated is no longer the running one. After a test passes and the change is on master, make it the boot default as well (`nix-env -p /nix/var/nix/profiles/system --set <out>` then `<out>/bin/switch-to-configuration boot`), or the next reboot boots the old generation.

### Confirm what's actually running

```sh
sudo nixos-rebuild list-generations | tail -5    # current generation + build date
readlink /run/current-system                     # toplevel store path
nix store diff-closures /run/booted-system /run/current-system   # what changed since last boot
```

The "Configuration Revision" column is empty until `system.configurationRevision` is wired into the flake — pending follow-up. Until then, verify the active config by checking expected services (`systemctl status ledger`) or firewall state (`sudo iptables -L INPUT -n | grep dpt`).

### Change anything that can touch AdGuard or networking

The whole house resolves through kakapo, so verify with `scripts/guarded-test.sh <built system>` instead of a bare `switch-to-configuration test`: it rolls back to the running system if AdGuard stops answering for ~6 seconds. Test any AdGuard startup change *inside its real sandbox* (`SystemCallFilter`, `DynamicUser`), not on a copy outside it — a preStart step that passed outside the sandbox was killed by seccomp inside it on 2026-10-05 and took the house's DNS down for two minutes. `dns-health` emails if DNS stays down.

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
5. Give it a name. For anything the whole house should reach, add `<name> = <port>;` to `proxied` (and any extra nginx directives to `serverExtra`) in `modules/services/lan-proxy.nix`; it becomes `https://<name>.salehtl.com` on the LAN and tailnet, DNS record included. For tailnet-only apps, add it to `tailnetOnly` instead (gated by tailscale-nginx-auth). Since 2026-10-07 nothing uses `tailscale serve`, and the `tailscale-serve-reset` oneshot (lan-proxy.nix) clears its config at every boot, so every app has one route and one gate.
6. Push to a feature branch, verify with `nixos-rebuild test` from the branch, merge.

kakapo has no public ingress: Forgejo (`git.sirdab.ae`), the public nginx, Postgres and the Cloudflare Tunnel (`cloudflared`) were removed on 2026-10-03. The nginx in `lan-proxy.nix` (2026-10-05) is LAN-only and is not public ingress. A public app would need a new tunnel and token, and a Cloudflare Access policy for anything private.

## Conventions worth preserving

- SSH is key-only; do not re-enable password auth or root login.
- `system.stateVersion` is set per-host and must not be bumped casually — it pins stateful-service defaults to the install-time NixOS release.
- Firewall is enabled by default. Port 22 is the only port open globally —
  on *every* interface, not just `tailscale0` (the two interface-scoped
  exceptions, `:53` and `:443`, are below). That is deliberate: Tailscale is the sole
  remote-access path, so the LAN is the recovery route when it is down. Do not
  narrow it to the tailnet.
- Self-hosted services listen on `localhost:<port>` and are reached through the
  LAN proxy (`modules/services/lan-proxy.nix`): `proxied` for the house,
  `tailnetOnly` for tailnet devices only. Never via newly-opened ports. The sole exception is AdGuard Home's resolver on
  `:53` — `tailscale serve` cannot carry UDP, so there is no way to reach a
  resolver through it. That exception is scoped with
  `networking.firewall.interfaces` (never the global port list), compensated by
  `dns.allowed_clients` + `ratelimit`, and guarded by assertions in
  `modules/services/adguard.nix`. Do not treat it as precedent for opening a
  port to anything that *can* be proxied.
- The second exception is `:443` on the LAN NIC and `tailscale0` (where the subnet route lands), for the
  `<service>.salehtl.com` proxy in `modules/services/lan-proxy.nix` (approved by
  Saleh on 2026-10-05). `tailscale serve` can only present the `*.ts.net`
  certificate and only reaches tailnet devices; this exists for devices that
  are not on the tailnet. nginx binds `10.0.0.215`, never `0.0.0.0`, because
  tailscaled claims the tailnet address.s `:443` whenever `tailscale serve` is
  used. Never put ledger
  (tailnet-only by policy) behind it, and never put Grafana in the
  unauthenticated `proxied` set: Grafana's `auth.proxy` trusts a header from
  loopback, which is where nginx connects from. `grafana.salehtl.com`
  (2026-10-06, Saleh's choice) instead has its own vhost behind
  `services.nginx.tailscaleAuth`: nginx asks tailscaled who the connecting
  tailnet address is and sets `Tailscale-User-Login` itself (from
  `$auth_user`, the full `salehtl@github`), overwriting any client copy, so
  only tailnet devices get in and plain-LAN clients get 401. Assertions enforce
  all three. AdGuard's UI is on it without a login, by Saleh's choice
  (2026-10-05).
- Secrets live in `secrets/<service>.yaml` (encrypted via sops), one file per service. Edit with `sops secrets/<service>.yaml`; declare each new secret in `modules/sops.nix` with its `sopsFile` and `restartUnits` pointing at any service that consumes it.
- `users.mutableUsers = false` — never `useradd`/`passwd` on the host; the flake is the only path. `wheelNeedsPassword = false` because `saleh` has no declared password (SSH key is the sole auth factor).
- The three host-level `assertions` are guardrails, not ceremony. Don't weaken them — if one fires, the underlying config is wrong, not the assertion.
- `nix fmt` before committing. CI's `nix flake check` will fail on unformatted code.

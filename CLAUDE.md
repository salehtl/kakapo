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

CI (`.github/workflows/check.yml`) runs `nix flake check` on every push to master and on PRs — this evaluates `nixosConfigurations.kakapo` and runs the formatter check, but does **not** build the toplevel derivation. CI is **advisory, not enforcing** — without GitHub branch protection requiring `check` to pass, `system.autoUpgrade` will pull master regardless of red checks. Treat a red CI run on master as an emergency: fix or revert before 04:00.

## Architecture

Composition is layered; each layer only knows about the one below it:

- `flake.nix` → wires `nixpkgs` (channel `nixos-25.05`) and `treefmt-nix` into `nixosConfigurations.kakapo`, plus exposes `formatter` + `checks.formatting` per system.
- `treefmt.nix` → formatter config: `nixfmt-rfc-style` + `deadnix` + `statix`.
- `hosts/kakapo/default.nix` → **host identity + invariants**: hostname, bootloader (systemd-boot + EFI), declared users (`saleh`, `humaid`) + their SSH keys, `users.mutableUsers = false`, `security.sudo.wheelNeedsPassword = false`, docker, firewall open only on port 22, and three eval-time `assertions` guarding hostname/`saleh`-SSH-key-presence/firewall. Imports `hardware.nix` + the shared modules.
- `hosts/kakapo/hardware.nix` → disks (UUID-pinned ext4 root + vfat /boot + /mnt/media), kernel modules (`kvm-amd`, `igb` NIC), AMD microcode. This is the file to touch for storage/hardware changes.
- `modules/base.nix` → **shared baseline** suitable for any host: flakes + weekly GC (`--delete-older-than 30d`), `Asia/Dubai` timezone, en_US.UTF-8, a small CLI package set, hardened OpenSSH (no root, no password), firewall on, auto-upgrade.
- `modules/server.nix` → **headless-server overrides**: disables fontconfig, blocks suspend/hibernate, forces `logind` to ignore lid switches, pins CPU governor to `performance`, disables emergency mode.
- `modules/dev.nix` → **forge stack** for `git.sirdab.ae`: Forgejo (Postgres-backed, LFS on, registration disabled, repos forced private, SSH on port 2222 advertised as 22, HTTP on 3939), nginx as a TLS-recommended reverse proxy on the public hostname with a 50 GB `client_max_body_size` for LFS pushes, and Postgres 17 with `postgis` + `pgvector`. Note: nginx listens on 80 but the firewall doesn't open it — public traffic enters via the Cloudflare Tunnel routing `git.sirdab.ae` → `http://localhost:80`, where nginx then proxies to Forgejo. This module is the **exception** to the "services bind to localhost" convention because nginx is the in-host proxy in front of Forgejo.
- `modules/sops.nix` → **secrets**: declares `sops-nix` config, derives the host's age decryption key from `/etc/ssh/ssh_host_ed25519_key`, and registers each secret declared in `secrets/kakapo.yaml` to be exposed at `/run/secrets/<name>` at boot.
- `modules/services/cloudflared.nix` → **public ingress**: `cloudflared` systemd unit (DynamicUser, hardened) running in token-based mode. Token is read from `/run/secrets/cloudflared/token` via systemd `LoadCredential`. Ingress (subdomain → local port) is configured in the Cloudflare Zero Trust dashboard, not in the flake. Public traffic from the internet enters via outbound tunnel — no inbound ports needed beyond SSH.

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

The "Configuration Revision" column is empty until `system.configurationRevision` is wired into the flake — pending follow-up. Until then, verify the active config by checking expected services (`systemctl status cloudflared`) or firewall state (`sudo iptables -L INPUT -n | grep dpt`).

### Edit secrets

```sh
sops secrets/kakapo.yaml         # opens $EDITOR with decrypted view; auto-encrypts on save
sops -d secrets/kakapo.yaml      # decrypt to stdout (one-off inspect)
```

On **macOS**, sops looks for the age key at `~/Library/Application Support/sops/age/keys.txt` by default, but ours lives at `~/.config/sops/age/keys.txt`. Set this in `~/.zshrc`:

```sh
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

### Add a new secret

1. `sops secrets/kakapo.yaml` and add an entry under a service-namespaced path (e.g. `vaultwarden.admin_token`).
2. In `modules/sops.nix`, declare it with `restartUnits = [ "<service>.service" ]` so the consuming service restarts on rotation.
3. Reference its decrypted path via `config.sops.secrets."<service>/<name>".path` (resolves to `/run/secrets/<service>/<name>` at runtime). Prefer systemd `LoadCredential = "<name>:${config.sops.secrets."...".path}"` over passing the path directly to a service — keeps the secret out of process arglists.

### Add a new self-hosted app

1. Create `modules/services/<app>.nix` enabling the upstream NixOS service for that app, **pinned to listen on `127.0.0.1:<port>`** (never `0.0.0.0` — public ingress is via the tunnel, not the firewall).
2. Wire any secrets it needs through sops (see above).
3. Import the module from `hosts/kakapo/default.nix`.
4. Declare any persistent state under `/var/lib/<app>` and note its path in the module's comment header — useful when storage layout changes later.
5. Push to a feature branch, verify with `nixos-rebuild test` from the branch, merge.
6. In the **Cloudflare Zero Trust dashboard** (Networks → Tunnels → kakapo's tunnel → Public Hostnames): add `<sub>.salehtl.com` → `http://localhost:<port>`. Subdomains follow the **function-not-software** convention (`tv` not `jellyfin`, `vault` not `vaultwarden`).
7. **Add a Cloudflare Access policy** for any app exposing private data — anything on the tunnel is publicly reachable unless gated by Access.

## Conventions worth preserving

- SSH is key-only; do not re-enable password auth or root login.
- `system.stateVersion` is set per-host and must not be bumped casually — it pins stateful-service defaults to the install-time NixOS release.
- Firewall is enabled by default and only port 22 is open. New self-hosted services should be reached **via the Cloudflare Tunnel**, not via newly-opened public ports — declare the service to listen on `localhost:<port>` and add a public-hostname route in the Cloudflare Zero Trust dashboard pointing at that port. Subdomains follow the `function-not-software` convention (`tv.salehtl.com` not `jellyfin.salehtl.com`).
- Secrets live in `secrets/kakapo.yaml` (encrypted via sops). Edit with `sops secrets/kakapo.yaml`; declare each new secret in `modules/sops.nix` with `restartUnits` pointing at any service that consumes it.
- `users.mutableUsers = false` — never `useradd`/`passwd` on the host; the flake is the only path. `wheelNeedsPassword = false` because `saleh` has no declared password (SSH key is the sole auth factor).
- The three host-level `assertions` are guardrails, not ceremony. Don't weaken them — if one fires, the underlying config is wrong, not the assertion.
- `nix fmt` before committing. CI's `nix flake check` will fail on unformatted code.

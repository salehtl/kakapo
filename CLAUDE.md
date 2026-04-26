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

CI (`.github/workflows/check.yml`) runs `nix flake check` + builds the kakapo toplevel on every push to master and on PRs. CI is **advisory, not enforcing** — without GitHub branch protection requiring `check` to pass, `system.autoUpgrade` will pull master regardless of red checks. Treat a red CI run on master as an emergency: fix or revert before 04:00.

## Architecture

Composition is layered; each layer only knows about the one below it:

- `flake.nix` → wires `nixpkgs` (channel `nixos-25.05`) and `treefmt-nix` into `nixosConfigurations.kakapo`, plus exposes `formatter` + `checks.formatting` per system.
- `treefmt.nix` → formatter config: `nixfmt-rfc-style` + `deadnix` + `statix`. `modules/caddy.nix` is excluded from `deadnix` so its scaffolding `mkRP` helper isn't pruned.
- `hosts/kakapo/default.nix` → **host identity + invariants**: hostname, bootloader (systemd-boot + EFI), the `saleh` user + SSH key, `users.mutableUsers = false`, `security.sudo.wheelNeedsPassword = false`, docker, open firewall ports (22/80/443), and three eval-time `assertions` guarding hostname/SSH-key-presence/firewall. Imports `hardware.nix` + the three shared modules.
- `hosts/kakapo/hardware.nix` → disks (UUID-pinned ext4 root + vfat /boot + /mnt/media), kernel modules (`kvm-amd`, `igb` NIC), AMD microcode. This is the file to touch for storage/hardware changes.
- `modules/base.nix` → **shared baseline** suitable for any host: flakes + weekly GC (`--delete-older-than 30d`), `Asia/Dubai` timezone, en_US.UTF-8, a small CLI package set, hardened OpenSSH (no root, no password), firewall on, auto-upgrade.
- `modules/server.nix` → **headless-server overrides**: disables fontconfig, blocks suspend/hibernate, forces `logind` to ignore lid switches, pins CPU governor to `performance`, disables emergency mode.
- `modules/caddy.nix` → **public reverse proxy** for `*.salehtl.com`. Defines a `mkRP sub port` helper and an empty `virtualHosts` merge list. New public services are exposed by adding `(mkRP "<sub>" <port>)` entries — name subdomains by **function**, not software (`tv` not `jellyfin`, `vault` not `vaultwarden`). ACME email is `salehtl@icloud.com`; ports 80/443 must stay open in the host firewall.

When adding a new host, create `hosts/<name>/{default.nix,hardware.nix}`, add a `nixosConfigurations.<name>` entry in `flake.nix`, and reuse `modules/base.nix` (+ `server.nix` if headless). Keep host-specific state (hostname, users, ports, services) in the host's `default.nix`; promote anything that would apply to multiple hosts into `modules/`.

## Conventions worth preserving

- SSH is key-only; do not re-enable password auth or root login.
- `system.stateVersion` is set per-host and must not be bumped casually — it pins stateful-service defaults to the install-time NixOS release.
- Firewall is enabled by default; new services need explicit `networking.firewall.allowedTCPPorts` / `allowedUDPPorts` entries in the host file.
- `users.mutableUsers = false` — never `useradd`/`passwd` on the host; the flake is the only path. `wheelNeedsPassword = false` because `saleh` has no declared password (SSH key is the sole auth factor).
- The three host-level `assertions` are guardrails, not ceremony. Don't weaken them — if one fires, the underlying config is wrong, not the assertion.
- `nix fmt` before committing. CI's `nix flake check` will fail on unformatted code.

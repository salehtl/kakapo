# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Single-host NixOS flake for the `kakapo` server (x86_64-linux, AMD, headless). The flake exposes one output: `nixosConfigurations.kakapo`.

## Common commands

Rebuild the system (run on the host, from this flake dir or with `--flake <path>`):

```sh
sudo nixos-rebuild switch --flake .#kakapo   # apply now + set as default
sudo nixos-rebuild test   --flake .#kakapo   # apply without making it default
sudo nixos-rebuild boot   --flake .#kakapo   # stage for next boot only
```

Evaluate/validate without a host:

```sh
nix flake check                              # evaluate all outputs
nix build .#nixosConfigurations.kakapo.config.system.build.toplevel
nix flake update                             # bump flake.lock (nixpkgs)
```

Note: `modules/base.nix` enables `system.autoUpgrade` pointing at `github:salehtl/kakapo#${config.networking.hostName}` at 04:00 daily (no auto-reboot). Whatever is on `master` at upgrade time is what the host runs — push with care.

## Architecture

Composition is layered; each layer only knows about the one below it:

- `flake.nix` → wires `nixpkgs` (channel `nixos-25.05`) into `nixosConfigurations.kakapo`, whose sole module is `./hosts/kakapo`.
- `hosts/kakapo/default.nix` → **host identity**: hostname, bootloader (systemd-boot + EFI), the `saleh` user + SSH key, docker, open firewall ports (22/80/443). Imports `hardware.nix` + the two shared modules.
- `hosts/kakapo/hardware.nix` → disks (UUID-pinned ext4 root + vfat /boot + /mnt/media), kernel modules (`kvm-amd`, `igb` NIC), AMD microcode. This is the file to touch for storage/hardware changes.
- `modules/base.nix` → **shared baseline** suitable for any host: flakes + weekly GC (`--delete-older-than 30d`), `Asia/Dubai` timezone, en_US.UTF-8, a small CLI package set, hardened OpenSSH (no root, no password), firewall on, auto-upgrade.
- `modules/server.nix` → **headless-server overrides**: disables fontconfig, blocks suspend/hibernate, forces `logind` to ignore lid switches, pins CPU governor to `performance`, disables emergency mode.

When adding a new host, create `hosts/<name>/{default.nix,hardware.nix}`, add a `nixosConfigurations.<name>` entry in `flake.nix`, and reuse `modules/base.nix` (+ `server.nix` if headless). Keep host-specific state (hostname, users, ports, services) in the host's `default.nix`; promote anything that would apply to multiple hosts into `modules/`.

## Conventions worth preserving

- SSH is key-only; do not re-enable password auth or root login.
- `system.stateVersion` is set per-host and must not be bumped casually — it pins stateful-service defaults to the install-time NixOS release.
- Firewall is enabled by default; new services need explicit `networking.firewall.allowedTCPPorts` / `allowedUDPPorts` entries in the host file.

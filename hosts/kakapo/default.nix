{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware.nix
    ../../modules/base.nix
    ../../modules/ca-trust.nix
    ../../modules/ci-runner.nix
    ../../modules/server.nix
    ../../modules/claude.nix
    ../../modules/guarded-upgrade.nix
    ../../modules/backup.nix
    ../../modules/notify.nix
    ../../modules/sops.nix
    ../../modules/nodejs.nix
    ../../modules/python.nix
    ../../modules/services/adguard.nix
    ../../modules/services/cliproxyapi.nix
    ../../modules/services/grampsweb.nix
    ../../modules/services/hasala.nix
    ../../modules/services/immich.nix
    ../../modules/services/lan-proxy.nix
    ../../modules/services/midstudy.nix
    ../../modules/services/monitoring.nix
    ../../modules/services/ntfy.nix
    ../../modules/services/t3code.nix
    ../../modules/services/zapret.nix
  ];

  networking.hostName = "kakapo";
  networking.networkmanager.enable = true;

  # Resolve through Cloudflare's filtering resolvers, never through what DHCP
  # hands out: the 04:00 upgrade must not depend on a LAN resolver, least of
  # all kakapo's own AdGuard (asserted in modules/services/adguard.nix).
  # `dns = "none"` is the load-bearing half: `networking.nameservers` only puts
  # these servers first, and NetworkManager would still append the DHCP one.
  # Tailscale leaves resolv.conf alone (`--accept-dns=false` in base.nix).
  # IPv4 only: this host has no IPv6 default route.
  networking.networkmanager.dns = "none";
  networking.nameservers = [
    "1.1.1.2" # Cloudflare, malware-filtering
    "1.0.0.2"
  ];

  # rabbit (Saleh's Mac) by its MagicDNS name, for kakapo itself, which does
  # not use MagicDNS: T3 Code links to another machine's t3 only by https or a
  # Tailscale name. If rabbit re-registers and gets a new address
  # (`tailscale status`), update it here.
  networking.hosts."100.118.80.39" = [ "rabbit.marmoset-paradise.ts.net" ];

  boot.loader.systemd-boot.enable = true;
  # Bounds /boot (vfat, 1 GiB): each distinct kernel+initrd pair costs ~41 MiB,
  # and a full /boot makes nixos-rebuild fail — silently, at 04:00.
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;

  users.mutableUsers = false;
  users.users.saleh = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN0xPWnKwUvjBNhRRyhuXcgdsCwl78vxow4N2EB7SX2IAAAACnNzaDprYWthcG8= saleh kakapo-yubikey"
      # Second YubiKey, kept apart from the first as a backup.
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIM3dCHcJciaFpvyZgtrpx9aB8NeJCvOvf4GwDTjINJvZAAAAEXNzaDprYWthcG8tYmFja3Vw saleh kakapo-yubikey-2"
      # A YubiKey used from Termius on Saleh's iPhone. Termius makes its own
      # FIDO2 key, so this is separate from the two keys above.
      "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBKPG9xjjNKWrRf/THvkJEmPlDD4NueoP3iN/L4Sf6Jw7T04HHJUXEyd3PcR0G2Mmy87Jl4QNoM4fF7xEmUWw6qoAAAALdGVybWl1cy5jb20= saleh kakapo-iphone-yubikey"
    ];
  };
  users.users.humaid = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIC+JivWVZLN5Q+gQp+Y+YOHr0tglTPujT5uqz0Vk//YnAAAABHNzaDo= HK05"
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIBDT3fTXfORHii5qehplQUj0JQztBhELP9D+22/8cg+9AAAAD3NzaDpodW1haWQtYW5vYQ== humaid-nano-anoa-ssh-git"
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLEmHSloW9GlnGAQWTf/bBgbDEhQ6NZCsbd3QKb/yJ+9GrVfq0yensVsoHlI4+Ozq01qs7bIXc4W6gPSmT4PAA0="
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  virtualisation.docker.enable = true;

  # Unfree packages by name. Only this host's own package set: pkgs.unstable
  # has its own predicate in flake.nix.
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "nvidia-x11"
      "nvidia-settings"
      "nvidia-persistenced"
      # T3 Code's Antigravity runtime (modules/services/t3code.nix).
      "agy-acp-server"
    ];
  # Project dev environments (modules/claude-projects.md): a project's `.envrc`
  # loads its flake devShell on `cd`. nix-direnv roots it against GC while the
  # project's .direnv/ exists.
  programs.direnv.enable = true;

  # For Termius on the phone, so a session survives network changes. The login
  # is still sshd's. No firewall opening: mosh is used only over the tailnet,
  # where tailscaled's ts-input chain accepts tailscale0 ahead of nixos-fw.
  programs.mosh = {
    enable = true;
    openFirewall = false;
    withUtempter = false;
  };

  environment.systemPackages = [
    pkgs.unstable.claude-code
    pkgs.unstable.herdr
    pkgs.unstable.tuios
    pkgs.gh
  ];

  # Every interface on purpose, not just tailscale0: the LAN is the recovery
  # route when Tailscale is down. SSH is key-only with a YubiKey. Do not narrow
  # this to the tailnet.
  networking.firewall.allowedTCPPorts = [ 22 ];

  system.stateVersion = "25.11";

  assertions = [
    {
      assertion = config.networking.hostName == "kakapo";
      message = "networking.hostName must be 'kakapo' — system.autoUpgrade pulls github:salehtl/kakapo#\${hostname}, so renaming the host silently breaks nightly upgrades.";
    }
    {
      assertion = (builtins.length config.users.users.saleh.openssh.authorizedKeys.keys) > 0;
      message = "users.users.saleh.openssh.authorizedKeys.keys is empty — SSH is key-only with no password auth, so this would lock you out of the host permanently.";
    }
    {
      assertion =
        !config.services.openssh.settings.PasswordAuthentication
        && !config.services.openssh.settings.KbdInteractiveAuthentication;
      message = "services.openssh.settings.PasswordAuthentication and KbdInteractiveAuthentication must both be false — SSH is key-only, and keyboard-interactive is a password prompt through PAM.";
    }
    {
      assertion = config.networking.firewall.enable;
      message = "networking.firewall.enable must be true — kakapo exposes port 22 and serves apps over the tailnet only; disabling the firewall would silently expose every other listening service.";
    }
    {
      assertion =
        let
          f = config.services.tailscale.extraSetFlags;
        in
        builtins.elem "--ssh=false" f && !(builtins.elem "--ssh" f) && !(builtins.elem "--ssh=true" f);
      message = "Tailscale SSH must stay off (services.tailscale.extraSetFlags needs \"--ssh=false\") — it authenticates the device, not the user, runs socket forwarding as root (tailworm.com, 2026-10), and the tailnet SSH policy admits root. sshd serves port 22 on the tailnet with the YubiKey keys instead.";
    }
  ];
}

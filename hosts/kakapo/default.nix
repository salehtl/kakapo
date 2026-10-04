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
    ../../modules/server.nix
    ../../modules/claude.nix
    ../../modules/sops.nix
    ../../modules/services/ledger.nix
    ../../modules/services/monitoring.nix
  ];

  networking.hostName = "kakapo";
  networking.networkmanager.enable = true;

  # Resolve through Cloudflare's filtering resolvers, not through whatever DHCP
  # hands out. The LAN resolver DHCP was advertising (10.0.0.10, a DNS add-on on
  # the Home Assistant Pi) stopped answering on :53 on 2026-10-04 and took this
  # host's name resolution with it — including the 04:00 autoUpgrade's ability
  # to fetch the flake. A server's deploy path should not depend on an add-on
  # running on an appliance.
  #
  # `dns = "none"` is the load-bearing half: `networking.nameservers` registers
  # a resolvconf entry at metric 1, which only puts these servers *first* —
  # NetworkManager still appends the DHCP one underneath. Telling NM to stay out
  # of resolv.conf entirely is what actually removes 10.0.0.10.
  #
  # Tailscale is unaffected: tailscaled owns resolv.conf at runtime, keeps
  # serving MagicDNS on 100.100.100.100, and takes these as its upstreams.
  #
  # IPv4 only on purpose — this host has no IPv6 default route, so v6 resolvers
  # would be dead entries that cost a timeout each.
  networking.networkmanager.dns = "none";
  networking.nameservers = [
    "1.1.1.2" # Cloudflare, malware-filtering
    "1.0.0.2"
  ];

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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAzToDCcubUsNikrT0cb6spONIcz/UUU0hGb93COQldz salehtl@icloud.com"
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIN0xPWnKwUvjBNhRRyhuXcgdsCwl78vxow4N2EB7SX2IAAAACnNzaDprYWthcG8= saleh kakapo-yubikey"
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

  # Allow unfree packages by name rather than all unfree packages.
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "claude-code"
      "nvidia-x11"
      "nvidia-settings"
      "nvidia-persistenced"
    ];
  environment.systemPackages = [
    pkgs.claude-code
    pkgs.herdr
  ];

  # Deliberately every interface, not just tailscale0. Tailscale is the sole
  # remote-access path, so a LAN fallback is the recovery route when it is
  # unavailable; this box sits on a trusted home LAN and SSH is key-only with
  # a YubiKey, which bounds the exposure. Do not narrow this to the tailnet.
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
      assertion = config.networking.firewall.enable;
      message = "networking.firewall.enable must be true — kakapo exposes port 22 and serves apps over the tailnet only; disabling the firewall would silently expose every other listening service.";
    }
  ];
}

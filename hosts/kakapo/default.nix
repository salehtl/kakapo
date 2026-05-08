{ config, ... }:
{
  imports = [
    ./hardware.nix
    ../../modules/base.nix
    ../../modules/server.nix
    ../../modules/dev.nix
    ../../modules/sops.nix
    ../../modules/services/cloudflared.nix
  ];

  networking.hostName = "kakapo";
  networking.networkmanager.enable = true;

  boot.loader.systemd-boot.enable = true;
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
      message = "networking.firewall.enable must be true — kakapo exposes port 22 and routes app traffic via Cloudflare Tunnel; disabling the firewall would silently expose every other listening service.";
    }
  ];
}

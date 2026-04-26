{ ... }:
{
  imports = [
    ./hardware.nix
    ../../modules/base.nix
    ../../modules/server.nix
    ../../modules/caddy.nix
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

  security.sudo.wheelNeedsPassword = false;

  virtualisation.docker.enable = true;

  networking.firewall.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "25.11";
}

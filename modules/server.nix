{ lib, ... }:
{
  fonts.fontconfig.enable = lib.mkDefault false;

  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
  '';

  services.logind.lidSwitch = lib.mkForce "ignore";
  services.logind.lidSwitchExternalPower = lib.mkForce "ignore";

  powerManagement.cpuFreqGovernor = "performance";

  systemd.enableEmergencyMode = false;
}

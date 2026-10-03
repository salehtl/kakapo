{ lib, ... }:
{
  fonts.fontconfig.enable = lib.mkDefault false;

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
  };

  services.logind.settings.Login = {
    HandleLidSwitch = lib.mkForce "ignore";
    HandleLidSwitchExternalPower = lib.mkForce "ignore";
  };

  powerManagement.cpuFreqGovernor = "performance";

  systemd.enableEmergencyMode = false;
}

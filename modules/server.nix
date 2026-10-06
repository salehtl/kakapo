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

  # Hardware watchdog (sp5100_tco on kakapo's B450). systemd pets it; if the
  # kernel or PID 1 hangs, the board resets itself instead of sitting dead
  # until someone power-cycles it. On 2026-10-06 kakapo froze hard with no
  # log, panic or pstore record and stayed down 11 minutes -- with the house
  # resolving through it. Reboot gets a deadline too, so a stuck shutdown
  # cannot hold DNS down either.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "2min";
  };
}

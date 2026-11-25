# The 04:00 upgrade, guarded. system.autoUpgrade (modules/base.nix) still
# owns nixos-upgrade.service and its timer; this replaces what the unit runs
# (upstream: a bare `nixos-rebuild switch`). The unit builds master, activates
# it through scripts/guarded-test.sh (same lock, probes and rollback as an
# agent's test) and sets the boot default only when that passed; see
# scripts/guarded-upgrade.sh for the exit codes. A failure fails the unit, so
# notify-failure@ (modules/notify.nix) mails and pushes.
#
# The guard is the copy in the *running* system's store, not master's: a
# merged PR that changes guarded-test.sh or this module is judged by the
# previous version, and its own version first judges the upgrade after it.
#
# The unit is not restarted or stopped by the activation it starts
# (restartIfChanged = false and X-StopOnRemoval = false, both upstream).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  flake = lib.head (lib.splitString "#" config.system.autoUpgrade.flake);
  upgrade = pkgs.writeShellApplication {
    name = "kakapo-guarded-upgrade";
    # The unit's own PATH (nix, coreutils, findutils, grep, sed, systemd)
    # plus what guarded-test.sh needs.
    runtimeInputs = [
      pkgs.dnsutils
      pkgs.iproute2
      pkgs.iptables
      pkgs.util-linux
    ];
    runtimeEnv = {
      GUARD = "${../scripts/guarded-test.sh}";
      INSTALLABLE = "${flake}#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel";
    };
    text = builtins.readFile ../scripts/guarded-upgrade.sh;
  };
in
{
  systemd.services.nixos-upgrade.script = lib.mkForce "exec ${lib.getExe upgrade}";

  # By hand, as root: `kakapo-guarded-upgrade [<built system>]`.
  environment.systemPackages = [ upgrade ];

  assertions = [
    {
      assertion = config.system.autoUpgrade.enable && !config.system.autoUpgrade.allowReboot;
      message = "modules/guarded-upgrade.nix replaces nixos-upgrade's script and never reboots: keep system.autoUpgrade enabled with allowReboot = false.";
    }
  ];
}

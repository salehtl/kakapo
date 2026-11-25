# kakapo-ci: runs ci-local.sh by itself on every pushed PR head and on master,
# within seconds of the push (modules/ci-runner.sh says how).
#
# ci-local.sh (the deployed copy, from this flake's claude/skills) refuses
# forks and runs only commits on salehtl/kakapo. It runs as saleh because it
# posts statuses with saleh's gh login. Outbound only: GitHub is polled.
{ pkgs, ... }:
{
  systemd.services.kakapo-ci = {
    description = "Run kakapo CI (ci-local.sh) on new pushes";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = with pkgs; [
      bash
      coreutils
      gawk
      gh
      git
      gnused
      hostname
      jq
      nix
      util-linux
    ];
    environment = {
      HOME = "/home/saleh";
      CI_LOCAL = "${../claude/skills/kakapo-change/scripts/ci-local.sh}";
    };
    serviceConfig = {
      User = "saleh";
      Group = "users";
      ExecStart = "${pkgs.bash}/bin/bash ${./ci-runner.sh}";
      # No auto-restart: a dead loop must alert (notify-failure@), not hide.
      # A run killed by a restart leaves a pending status; after 15 min the
      # loop counts it stale and runs that commit again.
      KillMode = "control-group";
    };
  };
}

# kakapo-ci: runs ci-local.sh by itself on every pushed PR head and on master,
# within seconds of the push (modules/ci-runner.sh says how). Before it, an
# agent had to run ci-local.sh by hand, and the wait for that was most of
# CI's time: 67 s at the median, 30 min at p95, against a 35-40 s run.
#
# Same trust as before: ci-local.sh (the deployed copy, from this flake's
# claude/skills) refuses forks and runs only commits on salehtl/kakapo.
# It runs as saleh because it posts statuses with saleh's gh login, as an
# agent's manual run does. Outbound only; no port opened (GitHub is polled,
# not a webhook).
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

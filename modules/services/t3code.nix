# T3 Code: a control plane for coding agents (Claude Code, Codex), run as an
# always-on service so Saleh can drive kakapo from his phone or Mac. Agents run
# as saleh, who has passwordless sudo, and unattended: Saleh's choice
# (2026-10-09), since only he can reach it and Claude Code already has the
# same reach.
#
# Access:  https://t3.salehtl.com, tailnet devices only (the LAN proxy's
#          tailnetOnly list, behind tailscale-nginx-auth), and then only paired
#          devices. Pair one with `t3 pair` as saleh; revoke a lost one under
#          Settings -> Connections. A paired device is as sensitive as the
#          YubiKey. Never T3 Connect (a cloud relay off the tailnet), and never
#          `--tailscale`/`--tailscale-serve`: a second route without the gate.
# Package: pkgs.unstable.t3code, updated by the weekly flake bump; `t3 update`
#          and `t3 service install` are the upstream installer's way and do
#          not apply here.
# State:   ~/.t3 (threads, projects, settings, paired devices).
# Ports:   127.0.0.1:3773 only.
{ pkgs, ... }:
let
  t3code = pkgs.unstable.t3code.override { enableClaude = true; };
in
{
  systemd.services.t3code = {
    description = "T3 Code server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HOME = "/home/saleh";
      # Product usage events to PostHog are on by default.
      T3CODE_TELEMETRY_ENABLED = "false";
      # Agents run arbitrary commands: give them saleh's normal PATH (sudo from
      # /run/wrappers, then per-user and system packages), not systemd's
      # minimal one.
      PATH = pkgs.lib.mkForce "/run/wrappers/bin:/etc/profiles/per-user/saleh/bin:/run/current-system/sw/bin:${t3code}/bin";
    };
    serviceConfig = {
      User = "saleh";
      Group = "users";
      WorkingDirectory = "/home/saleh";
      ExecStart = "${t3code}/bin/t3 serve --mode web --no-browser --host 127.0.0.1 --port 3773 /home/saleh";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # `t3 pair`, `t3 project` and friends for saleh's shells.
  environment.systemPackages = [ t3code ];
  environment.variables.T3CODE_TELEMETRY_ENABLED = "false";
}

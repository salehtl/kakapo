# T3 Code: a control plane for coding agents (Claude Code, Codex). Installed
# like claude-code: no service, nothing listens until saleh starts it from an
# SSH or Remote Control session:
#
#   t3 serve --host 127.0.0.1 --port 3773 ~/some-project
#   t3 pair      # one-time link/QR to pair a phone or browser
#
# Never `--tailscale` / `--tailscale-serve`: nothing on kakapo uses tailscale
# serve (every app is behind the LAN proxy), and it would add a second route
# without the tailscale-nginx-auth gate. t3.salehtl.com is the HTTPS route.
#
# While it runs, tailnet devices reach it at https://t3.salehtl.com (the LAN
# proxy's tailnet-only list, behind tailscale-nginx-auth); otherwise that name
# returns 502. Agents run as saleh, who has passwordless sudo, so a paired
# device is as sensitive as the YubiKey. Do not use T3 Connect, a cloud relay
# that would make it reachable off the tailnet.
#
# Package: pkgs.unstable.t3code, updated by the weekly flake bump; `t3 update`
#          and `t3 service install` are the upstream installer's way and do
#          not apply here.
# State:   ~/.t3 (threads, projects, settings, paired devices).
{ pkgs, ... }:
{
  environment.systemPackages = [ (pkgs.unstable.t3code.override { enableClaude = true; }) ];

  # Product usage events to PostHog are on by default.
  environment.variables.T3CODE_TELEMETRY_ENABLED = "false";
}

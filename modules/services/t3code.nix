# T3 Code (github.com/pingdotgg/t3code, 2026-11-19): a web UI for coding
# agents (Codex, Claude Code). Package from nixpkgs-unstable (not in 26.05);
# only its headless server (`t3 serve`) runs here, not the Electron app.
#
# User:    its own system user `t3code`, by Saleh's choice (2026-11-19): no
#          sudo, no access to /home, and NoNewPrivileges. Agents run shell
#          commands as this user, so it must never join `wheel`, `docker` or
#          any group that reaches root or the house DNS.
# State:   /var/lib/t3code (0700, t3code): t3's data in `t3/`, the agents'
#          own logins in the home directory (`.codex`, `.claude`), and the
#          workspace in `work/`. Claude Code uses CLIProxyAPI on loopback
#          with its API key, so it needs no login here (2026-11-19). Codex
#          logs in out of band (CLAUDE.md, "T3 Code").
# Ingress: tailnet only, https://t3.salehtl.com via the LAN proxy's
#          `tailnetOnly` list (tailscale-nginx-auth), plus t3's own pairing:
#          a browser must present a one-time pairing token first
#          (`t3code-pair` on kakapo). Never `--lan`, `--tailscale-serve` or
#          `t3 up`: they bind off loopback or use tailscale serve.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  port = 3773;
  stateDir = "/var/lib/t3code";
  baseDir = "${stateDir}/t3";
  workDir = "${stateDir}/work";
  package = pkgs.unstable.t3code.override { enableClaude = true; };
  t3 = lib.getExe' package "t3";

  # Mint a one-time pairing token for a browser, as the service user.
  pair = pkgs.writeShellScriptBin "t3code-pair" ''
    exec /run/wrappers/bin/sudo -u t3code HOME=${stateDir} ${t3} pair --base-dir ${baseDir} "$@"
  '';
in
{
  users.users.t3code = {
    isSystemUser = true;
    group = "t3code";
    home = stateDir;
    shell = pkgs.bashInteractive;
  };
  users.groups.t3code = { };

  systemd.tmpfiles.settings.t3code = {
    ${baseDir}.d = {
      user = "t3code";
      group = "t3code";
      mode = "0700";
    };
    ${workDir}.d = {
      user = "t3code";
      group = "t3code";
      mode = "0700";
    };
  };

  systemd.services.t3code = {
    description = "T3 Code server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # What the agents run. Projects bring the rest from their own flakes.
    path = [
      package
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.ripgrep
      pkgs.git
      pkgs.openssh
      pkgs.nix
    ];
    environment = {
      HOME = stateDir;
      DISABLE_AUTOUPDATER = "1";
      # Claude Code talks to CLIProxyAPI (modules/services/cliproxyapi.nix),
      # which holds Saleh's Claude login, so `t3code` needs no login of its
      # own. The key comes from the credential below, set in the script.
      ANTHROPIC_BASE_URL = "http://127.0.0.1:${toString config.services.cliproxyapi.settings.server.port}";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    };
    script = ''
      ANTHROPIC_AUTH_TOKEN=$(<"$CREDENTIALS_DIRECTORY/cliproxy-api-key")
      export ANTHROPIC_AUTH_TOKEN
      exec ${t3} serve --mode web --host 127.0.0.1 --port ${toString port} --base-dir ${baseDir} --no-browser ${workDir}
    '';
    serviceConfig = {
      User = "t3code";
      Group = "t3code";
      StateDirectory = "t3code";
      StateDirectoryMode = "0700";
      WorkingDirectory = workDir;
      LoadCredential = [ "cliproxy-api-key:${config.sops.secrets."cliproxyapi/api_key".path}" ];
      Restart = "on-failure";
      RestartSec = 5;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      UMask = "0077";
      MemoryMax = "8G";
    };
  };

  environment.systemPackages = [ pair ];
}

{ config, pkgs, ... }:
{
  systemd.services.cloudflared = {
    description = "Cloudflare Tunnel (kakapo)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      DynamicUser = true;

      LoadCredential = "token:${config.sops.secrets."cloudflared/token".path}";

      ExecStart = pkgs.writeShellScript "cloudflared-tunnel-run" ''
        export TUNNEL_TOKEN=$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/token")
        exec ${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run
      '';

      Restart = "on-failure";
      RestartSec = "10s";

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
    };
  };
}

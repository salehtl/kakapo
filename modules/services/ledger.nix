# ledger: Saleh's budgeting PWA (github.com/salehtl/ledger), moved here from
# dinosaur on 2026-10-03. The module comes from that repository's flake
# (nix/module.nix); this file is kakapo's instance of it.
#
# State:   /var/lib/ledger/ledger.db (SQLite, real financial data, 0700)
#          /var/lib/ledger/backups (a copy before each new build first runs)
# Secret:  /run/secrets/ledger/env (secrets/ledger.yaml, see modules/sops.nix)
# Ingress: tailnet only, https://kakapo.<tailnet>.ts.net/ via `tailscale serve`.
#          NOT the Cloudflare Tunnel: the app holds financial data and is never
#          public. Do not add a public hostname for it.
# Deploy:  `nix flake update ledger`, commit, push; the 04:00 upgrade applies it.
{ config, ... }:
let
  port = 8090;
in
{
  services.ledger = {
    enable = true;
    # The database arrived by copy. A fresh one would ingest the whole
    # mailbox again and send each email through the paid AI check.
    requireDatabase = true;
    environmentFile = config.sops.secrets."ledger/env".path;
    settings = {
      server.listen = "127.0.0.1:${toString port}";
      # The mailbox address is LEDGER_IMAP_USERNAME in the secret, because
      # this repository is public.
      imap = {
        host = "imap.gmail.com";
        port = 993;
        auth = "app_password";
        folder = "INBOX";
        read_only = true;
        use_idle = true;
        poll_interval = "15m";
      };
      ai = {
        enabled = true;
        provider = "typesafe";
      };
    };
  };

  # tailscaled keeps the serve config in its own state. This unit applies it
  # at boot and removes it when the unit stops or leaves the config.
  systemd.services.ledger-tailscale-serve = {
    description = "Serve ledger to the tailnet over HTTPS";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.tailscale.package ];
    # tailscaled can take a while to come up at boot: keep retrying.
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      # A oneshot waits forever by default; never hold up nixos-rebuild.
      TimeoutStartSec = 60;
    };
    script = "tailscale serve --bg --https=443 http://127.0.0.1:${toString port}";
    preStop = "tailscale serve --https=443 off";
  };
}

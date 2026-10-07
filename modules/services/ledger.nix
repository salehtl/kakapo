# ledger: Saleh's budgeting PWA (github.com/salehtl/ledger), moved here from
# dinosaur on 2026-10-03. The module comes from that repository's flake
# (nix/module.nix); this file is kakapo's instance of it.
#
# State:   /var/lib/ledger/ledger.db (SQLite, real financial data, 0700)
#          /var/lib/ledger/backups (a copy before each new build first runs)
# Secret:  /run/secrets/ledger/env (secrets/ledger.yaml, see modules/sops.nix)
# Ingress: tailnet only, https://ledger.salehtl.com via the LAN proxy's
#          `tailnetOnly` list (tailscale-nginx-auth, modules/services/lan-proxy.nix).
#          ledger has no login of its own: that gate is its only access control.
#          Never the unauthenticated `proxied` list, never public.
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
}

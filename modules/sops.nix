_: {
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # One sops file per service under secrets/. There is no defaultSopsFile,
    # so every secret names its own sopsFile.

    # ledger's LEDGER_* environment, one multi-line value.
    secrets."ledger/env" = {
      sopsFile = ../secrets/ledger.yaml;
      key = "ledger/env";
      restartUnits = [ "ledger.service" ];
    };

    # iCloud app-specific password for the upgrade-failure email
    # (modules/notify.nix). Read per send, so nothing needs restarting.
    secrets."notify/smtp_password" = {
      sopsFile = ../secrets/notify.yaml;
      key = "notify/smtp_password";
    };

    # Cloudflare API token for the *.salehtl.com DNS-01 challenge
    # and the public A records (modules/services/lan-proxy.nix): Zone:DNS:Edit +
    # Zone:Read on salehtl.com. Read at each use, so nothing needs restarting.
    secrets."acme/cloudflare_token" = {
      sopsFile = ../secrets/acme.yaml;
      key = "acme/cloudflare_token";
    };

    # UniFi Network integration API key for the Dream Router 7 at
    # https://10.0.0.1 (X-API-KEY header). Nothing on the host consumes it
    # automatically; it is here so sessions on kakapo can read and change the
    # network config without pasting it. Owned by saleh so no sudo is needed.
    # Pass it to curl via --config on a pipe, never on the command line.
    secrets."unifi/api_key" = {
      sopsFile = ../secrets/unifi.yaml;
      key = "unifi/api_key";
      owner = "saleh";
    };
  };
}

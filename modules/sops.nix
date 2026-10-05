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

    # Cloudflare API token for the *.home.salehtl.com DNS-01 challenge
    # (modules/services/home-domain.nix): Zone:DNS:Edit + Zone:Read on
    # salehtl.com only. Read at each issue/renewal, so nothing needs restarting.
    secrets."acme/cloudflare_token" = {
      sopsFile = ../secrets/acme.yaml;
      key = "acme/cloudflare_token";
    };
  };
}

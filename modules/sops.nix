_: {
  sops = {
    defaultSopsFile = ../secrets/kakapo.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    secrets."cloudflared/token" = {
      key = "cloudflared/token";
      restartUnits = [ "cloudflared.service" ];
    };

    # ledger's LEDGER_* environment, one multi-line value. A separate file:
    # it was made on dinosaur from the public keys alone.
    secrets."ledger/env" = {
      sopsFile = ../secrets/ledger.yaml;
      key = "ledger/env";
      restartUnits = [ "ledger.service" ];
    };
  };
}

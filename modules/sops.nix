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
  };
}

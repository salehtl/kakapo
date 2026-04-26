_: {
  sops = {
    defaultSopsFile = ../secrets/kakapo.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    secrets."cloudflared/token" = {
      key = "cloudflared/token";
    };
  };
}

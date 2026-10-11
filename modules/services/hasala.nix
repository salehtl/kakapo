# Hasala: the QA backend for the Hasala iOS beta (github.com/salehtl/hasala).
# The module is that flake's nixosModules.default (infra/qa/nix/module.nix
# there); this file is kakapo's instance of it, as infra/qa/HOST-PR.md ("PR B")
# describes.
#
# Runs:     everything PartOf hasala.target, in hasala.slice (2 GB cap):
#           hasala-postgresql, hasala-db-setup, hasala-migrate (before every
#           start), hasalad (`hasalad serve`), the backup and health timers.
#           Kill switch: `sudo systemctl stop hasala.target`.
# Ingress:  PUBLIC through its OWN Cloudflare Tunnel (cloudflared-hasala.service,
#           outbound only; no port opened; approved by Saleh 2026-10-11): api.hasala.app +
#           ^/(api/v1/.*|hooks/gmail/pubsub)$ -> 127.0.0.1:8471, everything
#           else 404. Rendered and asserted by the module, linted by hasala's
#           CI. The API is never behind the LAN proxy (modules/services/lan-proxy.nix).
#           The tunnel is LOCALLY managed (config_src = local): never migrate
#           it to remote/dashboard management, which would replace this
#           allowlist with whatever the dashboard says.
# Database: its OWN PostgreSQL 17 (hasala-postgresql.service), unix socket only
#           at /run/hasala-postgresql, data /var/lib/hasala-postgresql/17.
#           NOT services.postgresql (that one is Immich's).
# State:    /var/lib/hasala (hasalad), /var/lib/hasala-ledger (purge ledger).
# Backups:  03:15 age-encrypted pg_dump + purge ledger -> /mnt/media/hasala-backup
#           (29 days; RequiresMountsFor, so never onto / behind an unmounted
#           media disk). No decryption key is on this host. No off-site copy yet.
# Admin:    `sudo hasala-admin <mode>` over SSH.
# Secrets:  secrets/hasala.yaml (modules/sops.nix), all through LoadCredential=.
# Ports:    127.0.0.1 only: API 8471, metrics 9471, cloudflared metrics 9472.
{ config, lib, ... }:
let
  cfg = config.services.hasala;
  secret = name: config.sops.secrets."hasala/${name}".path;

  # Not secret. A feature whose value is null stays off; the value here is the
  # whole switch (its secret in modules/sops.nix follows it). Set null to turn
  # the feature off again.
  #
  # The Cloudflare account id (32 lowercase hex) that owns the hasala-qa
  # tunnel and sends Hasala's mail. The tunnel needs outbound mail (module
  # assertion M11), so one value turns on both.
  cloudflareAccountId = "19251a3240f684663f05ab537e14d57e";
  # The APNs auth key's 10-character key id (the .p8 is hasala/apns_key_p8).
  # The module's default environments (production and sandbox) stay: TestFlight
  # builds use production, Xcode debug builds sandbox.
  apnsKeyId = "77N67W8RZW";

  # Every TCP port already bound on this host, as of this file.
  taken = [
    22 # sshd
    53 # AdGuard Home DNS
    443 # nginx, the LAN proxy
    2586 # ntfy
    3003 # Immich machine learning
    3773 # T3 Code
    5000 # Gramps Web
    8090 # ledger
    config.services.adguardhome.port
    config.services.grafana.settings.server.http_port
    config.services.immich.port
    config.services.postgresql.settings.port
    config.services.prometheus.port
    config.services.prometheus.exporters.node.port
    config.services.prometheus.exporters.nvidia-gpu.port
    config.services.prometheus.exporters.smartctl.port
  ];
in
{
  services.hasala = {
    enable = true;

    authKeyFile = secret "auth_key"; # spec 01 §4.11; generated once, never rotated in the beta

    email = lib.mkIf (cloudflareAccountId != null) {
      inherit cloudflareAccountId;
      apiTokenFile = secret "email_api_token";
    };
    tunnel = lib.mkIf (cloudflareAccountId != null) {
      enable = true;
      id = "d166d89d-c4e0-4c6a-9112-38e06c2d6d51"; # hasala-qa; not a secret (useless without tunnel_credentials)
      credentialsFile = secret "tunnel_credentials";
    };

    apns = lib.mkIf (apnsKeyId != null) {
      keyFile = secret "apns_key_p8";
      keyId = apnsKeyId;
    };

    # Gmail push stays off: the [gmail] group (google.iosClientId, gmail.*,
    # mailboxRouteKeyFile) is all or nothing (M8), and its push subscription
    # (projects/hasala-511307/subscriptions/<name>, endpoint and audience
    # https://api.hasala.app/hooks/gmail/pubsub) and the service account it
    # signs as do not exist yet. Known: client id
    # 987620996339-4tbl1o14pf309u5h9bjatnaipvqg1ob9.apps.googleusercontent.com,
    # topic projects/hasala-511307/topics/gmail-push. The phone still reads
    # Gmail itself; push only adds wake-ups. hasala/mailbox_route_key waits in
    # secrets/hasala.yaml for it.

    backup = {
      enable = true;
      # The media SSD (hosts/kakapo/hardware.nix), not the root disk.
      dir = "/mnt/media/hasala-backup";
      ageRecipients = [
        # Interim: Saleh's Mac sops key (&mac in .sops.yaml), so the identity
        # is on his Mac and never on this host. Spec 05 wants two dedicated
        # recipients (a Mac one and a printed offline one); replace this with
        # them before testers' data arrives.
        "age1r8cv2p7ftwlvfhm8lh25ej9ddtpmmkca0fnhszl4v4ggeuelz5qqeheus9"
      ];
      # Off-site (rclone to R2) stays off: there is no hasala/backup_rclone_conf
      # in secrets/hasala.yaml yet.
    };

    monitoring = {
      # Mail and phone push (modules/notify.nix) when any Hasala unit fails.
      onFailure = [ "notify-failure@%n.service" ];
      ntfyUrl = "http://127.0.0.1:2586/kakapo";
      healthCheck.enable = true;
    };

    # Every Hasala unit, and the hasala-admin sandbox, gets these: the module's
    # own defaults (the host's PostgreSQL, sops' secrets), then the other
    # finance app, then every other service's state. DynamicUser services'
    # state (AdGuard Home, ntfy) is under /var/lib/private, root-only, and
    # Hasala's own DynamicUser units need that directory, so it is not listed.
    hardening.inaccessiblePaths = [
      "-/var/lib/postgresql"
      "-/run/postgresql"
      "-/run/secrets"
      "-/var/lib/ledger"
      "-/mnt/media/immich"
      "-/var/lib/redis-immich"
      "-/var/lib/grampsweb"
      "-/var/lib/grafana"
      "-/var/lib/prometheus2"
      "-/var/lib/acme"
      "-/var/lib/tailscale"
      # The host keys every sops secret is decrypted with.
      "-/etc/ssh"
    ];
  };

  assertions = [
    {
      assertion = lib.all (p: !(lib.elem p taken)) [
        cfg.listen.port
        cfg.metrics.port
        cfg.tunnel.metricsPort
      ];
      message = "hasala: a port collides with one this host already uses (modules/services/hasala.nix).";
    }
  ];
}

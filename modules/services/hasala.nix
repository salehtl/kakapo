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
# Console:  the operator console (`hasalad console`, hasala-console.service, its
#           own OS user) at https://hasala.salehtl.com, TAILNET ONLY: the LAN
#           proxy's tailnetOnly list (modules/services/lan-proxy.nix) puts it
#           behind tailscale-nginx-auth, and the console admits only `logins`
#           below by the X-Webauth-User header nginx sets. The module's kernel
#           rule resets every local TCP connection to 127.0.0.1:8472 (and
#           [::1]:8472) that is not nginx's. Never public, never under
#           hasala.app (module assertion M18), never on the hasala-qa tunnel
#           (M16).
#           Threat (security review, 2026-10-12): a tailnet login is a user,
#           not a device. kakapo and homeassistant are untagged nodes logged
#           in as salehtl@github, tailscaled's WhoIs answers for kakapo's own
#           addresses too, and tailscale-nginx-auth refuses only tagged nodes.
#           So any local process on kakapo could connect to nginx from
#           kakapo's tailnet address (`curl --interface 100.98.60.126
#           --resolve hasala.salehtl.com:443:10.0.0.215 ...`), be named
#           salehtl@github, and mint, approve, revoke and resend; so could
#           anything on homeassistant, over the tailnet. Two controls, both in
#           modules/services/lan-proxy.nix (its header, "Identity"):
#             1. `lan-proxy-out`: locally generated TCP to :443 on this host's
#                own addresses from a tailnet address is reset, for every user.
#                `lan-proxy-spoof-check` tests it every two minutes, as nobody
#                from kakapo's tailnet address, and mails on failure.
#             2. The console's vhost answers only `consoleDevices`, Saleh's own
#                Mac and iPhone by tailnet address (`allow ...; deny all;`),
#                never kakapo, homeassistant or any server.
#           lan-proxy.nix also denies kakapo's and homeassistant's tailnet
#           addresses on every gated vhost (`untaggedDeny`), a stopgap until
#           Saleh tags both (tag:server) in the Tailscale admin, out-of-band:
#           nginx-auth then refuses them on every gated name (CLAUDE.md).
# Secrets:  secrets/hasala.yaml (modules/sops.nix), all through LoadCredential=.
# Ports:    127.0.0.1 only: API 8471, metrics 9471, cloudflared metrics 9472,
#           console 8472, console healthz 9473.
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
    # The password salt key (spec 01 §4.11): a separate 32-byte value, never
    # equal to auth_key and NEVER rotated (serve records its fingerprint on
    # first start and refuses a different one).
    saltKeyFile = secret "salt_key";

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

    # The operator console (spec 07; HOST-PR.md "PR C"). Its port and
    # metricsPort are the module's defaults, 8472 and 9473.
    console = {
      enable = true;
      # A LAN-proxy name (its tailnetOnly list), never a name under hasala.app
      # (M18). The console refuses any other Host header.
      host = "hasala.salehtl.com";
      # Full tailnet logins as tailscale-nginx-auth reports them in
      # X-Webauth-User (`tailscale status` shows them shortened to `salehtl@`).
      # The tailnet has other members, so this list is the console's access
      # control: never widen it to "anyone on the tailnet".
      logins = [ "salehtl@github" ];
      # The tailnet X-Webauth-Tailnet must name (lan-proxy.nix's tailnetName;
      # the console ignores the trailing dot nginx-auth sends).
      tailnet = "marmoset-paradise.ts.net";
      # The only user the kernel rule lets connect to the console port: the
      # LAN proxy's nginx (the module's default, spelled out).
      restrictToUser = config.services.nginx.user;
    };
    # TestFlight is manual until the App Store Connect server key is in sops.
    # A follow-up PR adds hasala/asc_key_p8 to secrets/hasala.yaml and
    # modules/sops.nix and switches it on, keeping refusedKeyIds below:
    #   asc = {
    #     enable = true;
    #     keyFile = secret "asc_key_p8";
    #     keyId = "<server App Manager key id>";
    #     keyKind = "team";
    #     issuerId = "<issuer UUID>";
    #   };
    # The Mac's App Store Connect upload key id (not secret). It must never
    # run on this host (M20, PQ-16); set now, as HOST-PR.md asks, so the
    # refusal is already in place when asc is switched on.
    asc.refusedKeyIds = [ "275JBFHQ4L" ];

    # Gmail's mailbox link (M8a): the iOS client id (not secret; it ships in
    # the app, ios/Config/Shared.xcconfig) and the route key, both or neither.
    # It mounts the app's Connect Gmail routes; without gmail.* below the app
    # fetches mail when opened or refreshed in the background, with no wakes.
    google.iosClientId = "987620996339-4tbl1o14pf309u5h9bjatnaipvqg1ob9.apps.googleusercontent.com";
    mailboxRouteKeyFile = secret "mailbox_route_key";
    # Gmail's Pub/Sub push (M8b) stays off: all four or none, only with the
    # link, and its push subscription (projects/hasala-511307/subscriptions/
    # <name>, endpoint and audience https://api.hasala.app/hooks/gmail/pubsub)
    # and the service account it signs as do not exist yet. Known: topic
    # projects/hasala-511307/topics/gmail-push. Order: topic and service
    # account, then the host PR setting gmail.*, then the subscription
    # (hasala's infra/qa/HOST-PR.md, "Gmail: the link now, the push later").

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
        cfg.console.port
        cfg.console.metricsPort
      ];
      message = "hasala: a port collides with one this host already uses (modules/services/hasala.nix).";
    }
    {
      # The module's M19 checks that exactly one gated vhost proxies to the
      # console; this checks it is the one named console.host, since the
      # console refuses every other Host header, and that the vhost carries
      # the device allow-list (control 2 in the header; lan-proxy.nix
      # asserts its contents).
      assertion =
        !cfg.console.enable
        || (
          lib.elem cfg.console.host config.services.nginx.tailscaleAuth.virtualHosts
          &&
            (config.services.nginx.virtualHosts.${cfg.console.host}.locations."/".proxyPass or null)
            == "http://127.0.0.1:${toString cfg.console.port}"
          && lib.hasSuffix "deny all;\n" (
            config.services.nginx.virtualHosts.${cfg.console.host}.extraConfig or ""
          )
        );
      message = "hasala: console.host (${toString cfg.console.host}) is not the LAN proxy's tailnet-only vhost for the console port with the device allow-list (`allow <Saleh's devices>; deny all;`); add it to tailnetOnly and consoleDevices in modules/services/lan-proxy.nix.";
    }
  ];
}

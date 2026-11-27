# Hasala: the QA backend for the Hasala iOS beta (github.com/Hasala/hasala).
# The module is that flake's nixosModules.default (infra/qa/nix/module.nix
# there); this file is kakapo's instance of it (infra/qa/HOST-PR.md).
#
# Runs:     everything PartOf hasala.target, in hasala.slice (2 GB cap):
#           hasala-postgresql, hasala-db-setup, hasala-migrate (before every
#           start), hasalad, the backup and health timers.
#           Kill switch: `sudo systemctl stop hasala.target`.
# Ingress:  PUBLIC through its OWN Cloudflare Tunnel (cloudflared-hasala.service,
#           outbound only, no port opened): api.hasala.app +
#           ^/(api/v1/.*|hooks/gmail/pubsub|hooks/outlook/graph(/lifecycle)?)$
#           -> 127.0.0.1:8471, everything else 404. Rendered and asserted by
#           the module. The API is never behind the LAN proxy.
#           The tunnel is LOCALLY managed (config_src = local): never migrate
#           it to dashboard management, which would replace this allowlist.
# Database: its OWN PostgreSQL 17 (hasala-postgresql.service), unix socket only
#           at /run/hasala-postgresql, data /var/lib/hasala-postgresql/17.
#           NOT services.postgresql (that one is Immich's).
# State:    /var/lib/hasala (hasalad), /var/lib/hasala-ledger (purge ledger).
# Backups:  03:15 age-encrypted pg_dump + purge ledger -> /mnt/media/hasala-backup
#           (29 days). No decryption key is on this host. No off-site copy yet.
# Admin:    `sudo hasala-admin <mode>` over SSH.
# Console:  the operator console (hasala-console.service, its own OS user) at
#           https://hasala.salehtl.com, TAILNET ONLY: the LAN proxy's
#           tailnetOnly list puts it behind tailscale-nginx-auth, and the
#           console admits only `logins` below by the X-Webauth-User header
#           nginx sets. The module's kernel rule resets every local TCP
#           connection to 127.0.0.1:8472 (and [::1]:8472) that is not nginx's.
#           Never public, never under hasala.app (module assertion M18), never
#           on the hasala-qa tunnel (M16).
#           A tailnet login is a user, not a device, so the vhost also answers
#           only Saleh's own devices: the threat and the controls are under
#           "Identity" in the header of modules/services/lan-proxy.nix.
# Secrets:  secrets/hasala.yaml (modules/sops.nix), all through LoadCredential=.
# Ports:    127.0.0.1 only: API 8471, cloudflared metrics 9472, console 8472,
#           console healthz and /metrics 9473.
#
# Never bind 127.0.0.1:8471 from anything else: the tunnel routes it publicly
# even while hasalad is down. No other app may be added to the hasala-qa
# tunnel. A missing media disk stops hasalad from starting (RequiresMountsFor).
# Check a release with `sudo hasala-admin version`.
{ config, lib, ... }:
let
  cfg = config.services.hasala;
  secret = name: config.sops.secrets."hasala/${name}".path;

  # Not secret. A null value turns its feature off (its secret in
  # modules/sops.nix follows it).
  #
  # The Cloudflare account that owns the hasala-qa tunnel and sends Hasala's
  # mail. The tunnel needs outbound mail (module assertion M11), so one value
  # turns on both.
  cloudflareAccountId = "19251a3240f684663f05ab537e14d57e";
  # The APNs auth key's key id (the .p8 is hasala/apns_key_p8). The module's
  # default environments stay: TestFlight builds use production, Xcode debug
  # builds sandbox.
  apnsKeyId = "77N67W8RZW";

  # Every TCP port already bound on this host.
  taken = [
    22 # sshd
    53 # AdGuard Home DNS
    443 # nginx, the LAN proxy
    2586 # ntfy
    3003 # Immich machine learning
    5000 # Gramps Web
    config.services.midstudy.webPort
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

    # The operator console (spec 07). Its port and metricsPort are the module's
    # defaults, 8472 and 9473.
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
      # The only user the kernel rule lets connect to the console port.
      restrictToUser = config.services.nginx.user;
    };
    # TestFlight is manual: the operator adds each invited tester by hand
    # (hasala's docs/decisions/testflight-manual.md; the module has no asc.*).

    # Gmail's mailbox link (M8a): the iOS client id (not secret, it ships in the
    # app) and the route key, both or neither. Without gmail.* the app fetches
    # mail only when opened or refreshed in the background.
    google.iosClientId = "987620996339-4tbl1o14pf309u5h9bjatnaipvqg1ob9.apps.googleusercontent.com";
    mailboxRouteKeyFile = secret "mailbox_route_key";
    # Gmail's Pub/Sub push (M8b) stays off until its push subscription and
    # service account exist (hasala's infra/qa/HOST-PR.md, "Gmail: the link now,
    # the push later"). Topic: projects/hasala-511307/topics/gmail-push.

    # Outlook's mailbox link (M8c): the Entra app's client id (not secret), with
    # the route key above. Its Graph push (M8d): both URLs or none, exactly
    # these two; the device creates the Graph subscription itself.
    outlook = {
      clientId = "0cbe5805-2e22-4f55-9785-9d3bdaf7009d";
      notificationUrl = "https://api.hasala.app/hooks/outlook/graph";
      lifecycleUrl = "https://api.hasala.app/hooks/outlook/graph/lifecycle";
    };

    # CORS for the website's public routes. The module's default is the same;
    # set here so the header does not depend on it.
    web.origins = [ "https://hasala.app" ];
    # With this set, the waitlist refuses a request that has no valid Turnstile
    # token (widget on hasala.app).
    web.turnstile.secretFile = config.sops.secrets."hasala/turnstile_secret".path;

    backup = {
      enable = true;
      # The media SSD (hosts/kakapo/hardware.nix), not the root disk.
      dir = "/mnt/media/hasala-backup";
      ageRecipients = [
        # Interim: Saleh's Mac sops key (&mac in .sops.yaml), so the identity is
        # never on this host. Spec 05 wants two dedicated recipients (a Mac one
        # and a printed offline one): replace this before testers' data arrives.
        "age1r8cv2p7ftwlvfhm8lh25ej9ddtpmmkca0fnhszl4v4ggeuelz5qqeheus9"
      ];
      # Off-site (rclone to R2) stays off: no hasala/backup_rclone_conf yet.
    };

    monitoring = {
      onFailure = [ "notify-failure@%n.service" ];
      ntfyUrl = "http://127.0.0.1:2586/kakapo";
      healthCheck.enable = true;
      # One notice per new early-access request. It names nobody and opens the
      # console.
      earlyAccessNotice = true;
    };

    # Hidden from every Hasala unit and the hasala-admin sandbox: the module's
    # own defaults, then every other service's state. DynamicUser state (AdGuard
    # Home, ntfy) is under /var/lib/private, which Hasala's own DynamicUser
    # units need, so it is not listed.
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
        cfg.tunnel.metricsPort
        cfg.console.port
        cfg.console.metricsPort
      ];
      message = "hasala: a port collides with one this host already uses (modules/services/hasala.nix).";
    }
    {
      # The module's M19 checks that exactly one gated vhost proxies to the
      # console; this checks it is the one named console.host and that it
      # carries the device allow-list (lan-proxy.nix asserts its contents).
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

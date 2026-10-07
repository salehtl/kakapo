# <service>.salehtl.com for every device in the house, not just the tailnet --
# TVs, guests' phones, anything on the LAN -- and for tailnet devices anywhere.
#
# Names:   One name per service directly under salehtl.com (plex.salehtl.com,
#          not plex.home.salehtl.com). Never a DNS wildcard: *.salehtl.com
#          would point every unlisted name on the domain, including any future
#          public site, at a LAN address. The names come from the lists below
#          and are published in two places that always agree:
#            - Public A records in Cloudflare, kept exact by lan-proxy-dns, for
#              everything that does not ask AdGuard: tailnet devices away from
#              home (the tailnet has no global nameserver, only MagicDNS) and
#              devices at home using iCloud Private Relay or their own DoH. They
#              reveal only a private address.
#            - /etc/hosts, for kakapo itself (it never resolves through its own
#              AdGuard) and for the LAN: AdGuard answers from it
#              (hostsfile_enabled), so the LAN resolves them with the internet
#              down. Not AdGuard rewrites: those live in its settings, and
#              every name change restarted the house's resolver (~3 s).
# TLS:     One wildcard certificate, *.salehtl.com, from Let's Encrypt via the
#          DNS-01 challenge on Cloudflare: nothing has to be reachable from the
#          internet, and service names stay out of Certificate Transparency
#          logs. Token: secrets/acme.yaml.
# Ingress: nginx on 10.0.0.215:443, firewall-scoped to the LAN NIC and
#          tailscale0. This is the second exception to "services are reached
#          through tailscale serve" (the first is AdGuard's :53): tailscale
#          serve can only present the *.ts.net certificate and only reaches
#          tailnet devices. Approved by Saleh on 2026-10-05. Port 80 stays
#          closed: DNS-01 needs no HTTP listener.
#
#          nginx binds the LAN address, not 0.0.0.0, because tailscaled already
#          listens on the tailnet address's :443 for `tailscale serve`, and a
#          wildcard bind would collide with it. 10.0.0.215 is a fixed DHCP
#          reservation in UniFi (see CLAUDE.md); ip_nonlocal_bind lets nginx
#          start before NetworkManager has brought the address up.
# Away:    kakapo advertises 10.0.0.215/32 as a Tailscale subnet route, so a
#          tailnet device anywhere reaches the LAN address through the tunnel.
#          A route to the host's own address is local delivery, not
#          forwarding. It needs a one-time approval in the Tailscale admin
#          console (Machines -> kakapo -> Edit route settings), which is
#          invisible from this flake. Linux clients also need
#          `--accept-routes`. The tailnet policy is allow-all, so no ACL change.
#
# Adding a service: add `<name> = <port>;` to `proxied` below. It becomes
# https://<name>.salehtl.com, proxied to 127.0.0.1:<port>, and its DNS record
# appears on the next activation. Removing it deletes the record. A service on
# another LAN machine goes in `lanUpstreams` as `<name> = "http://<ip>:<port>";`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  zone = "salehtl.com";
  lanAddress = "10.0.0.215";
  lanInterface = "enp4s0"; # same NIC as modules/services/adguard.nix

  # name -> 127.0.0.1 port, with no authentication added. Never Grafana (it
  # has its own vhost below) or ledger; see the assertions.
  proxied = {
    # No login, by Saleh's choice (2026-10-05): anyone on the LAN or tailnet
    # can change AdGuard's filtering. Revisit if that ever matters.
    adguard = config.services.adguardhome.port;
    # Immich has its own accounts (modules/services/immich.nix).
    photos = config.services.immich.port;
  };

  # name -> another machine on the LAN. Its traffic leaves kakapo from
  # lanAddress, so the upstream must trust 10.0.0.215 as a reverse proxy.
  lanUpstreams = {
    # Home Assistant Yellow. HA trusts 10.0.0.215 as a reverse proxy, set in its
    # UI (Settings -> System -> Network; HA now ignores the http: block in
    # configuration.yaml) and applied on restart. Without it HA answers every
    # proxied request with 400. That setting is out-of-band.
    home = "http://10.0.0.10:8123";
  };

  # name -> 127.0.0.1 port, reachable only by tailnet devices: behind
  # tailscale-nginx-auth like Grafana, but without the identity header. For
  # apps with their own login that are too dangerous for the plain LAN.
  tailnetOnly = {
    # ledger has no login of its own; this gate is its only access control
    # (modules/services/ledger.nix).
    ledger = ledgerPort;
    # T3 Code, when saleh has started it; agents run as saleh, who has
    # passwordless sudo (modules/services/t3code.nix).
    t3 = 3773;
  };
  tailnetOnlyNames = map (name: "${name}.${zone}") (lib.attrNames tailnetOnly);

  # Every name behind tailscale-nginx-auth, and the ports behind them.
  gatedNames = [ "grafana.${zone}" ] ++ tailnetOnlyNames;
  gatedPorts = [ grafanaPort ] ++ lib.attrValues tailnetOnly;
  # The tailnet as nginx-auth spells it: from the node's FQDN, so with the
  # trailing dot. Without the dot every request is 403 (verified 2026-10-07).
  tailnetName = "marmoset-paradise.ts.net.";
  # nixpkgs' expectedTailnet only sends Expected-Tailnet to the backend, never
  # to the /auth subrequest nginx-auth evaluates, so it checked nothing. Set
  # it on /auth: nodes shared in from another tailnet then get 403.
  tailnetGate = {
    locations."/auth".extraConfig = ''
      proxy_set_header Expected-Tailnet "${tailnetName}";
    '';
  };

  # name -> extra nginx server directives, for apps the defaults don't fit.
  # Applied to every list above. Directives only, never `location` blocks:
  # those would sit outside tailscale-nginx-auth (see the assertions).
  serverExtra = {
    # HA backups upload as one request, often hundreds of MB; nginx's 10m
    # default answered 413 before HA saw them.
    home = ''
      client_max_body_size 0;
    '';
    # Agent sessions hold a websocket open for as long as a turn runs.
    t3 = ''
      proxy_read_timeout 1h;
      proxy_send_timeout 1h;
    '';
    # Phone backups upload whole videos in one request; stream them straight
    # through instead of buffering to disk, and allow slow links.
    photos = ''
      client_max_body_size 50000M;
      proxy_request_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      send_timeout 600s;
    '';
  };

  grafanaPort = config.services.grafana.settings.server.http_port;
  ledgerPort = lib.toInt (
    lib.last (lib.splitString ":" config.services.ledger.settings.server.listen)
  );

  vhost =
    extra:
    {
      useACMEHost = zone;
      onlySSL = true;
    }
    // extra;

  proxyVhost =
    upstream:
    vhost {
      locations."/" = {
        proxyPass = upstream;
        proxyWebsockets = true;
        # Grafana's auth.proxy trusts these headers from loopback, which is
        # where nginx connects from. Never forward a client's copy.
        extraConfig = ''
          proxy_set_header Tailscale-User-Login "";
          proxy_set_header Tailscale-User-Name "";
        '';
      };
    };

  # Grafana logs in whoever its Tailscale-User-Login header names, trusting it
  # from loopback, which is where nginx connects from. So this vhost never
  # passes a client's header: it sets it from tailscaled's whois of the
  # connecting address (tailscale-nginx-auth). Tailnet devices arrive through
  # the subnet route with their tailnet address and are identified; anything
  # else fails whois and gets 401. Never put Grafana in `proxied`.
  grafanaVhost = vhost {
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString grafanaPort}";
      proxyWebsockets = true;
      # $auth_* are set by services.nginx.tailscaleAuth's auth_request.
      # $auth_user is the full login (salehtl@github), matching what tailscale
      # serve sends; $auth_login is only the part before the @.
      extraConfig = ''
        proxy_set_header Tailscale-User-Login $auth_user;
        proxy_set_header Tailscale-User-Name $auth_name;
      '';
    };
  };

  vhosts = {
    # Landing page, and the name to test the whole chain with.
    "kakapo.${zone}" = vhost {
      locations."/".extraConfig = ''
        default_type text/plain;
        return 200 "kakapo\n";
      '';
    };
    "grafana.${zone}" = grafanaVhost;
  }
  // lib.mapAttrs' (
    name: port:
    lib.nameValuePair "${name}.${zone}" (
      proxyVhost "http://127.0.0.1:${toString port}" // { extraConfig = serverExtra.${name} or ""; }
    )
  ) (proxied // tailnetOnly)
  // lib.mapAttrs' (
    name: url:
    lib.nameValuePair "${name}.${zone}" (proxyVhost url // { extraConfig = serverExtra.${name} or ""; })
  ) lanUpstreams;

  names = lib.attrNames vhosts;

  dnsSync = pkgs.writeShellApplication {
    name = "lan-proxy-dns";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = builtins.readFile ./lan-proxy-dns.sh;
  };
in
{
  # The LAN gets these names from /etc/hosts through AdGuard (hostsfile_enabled),
  # which watches the file, so a name change no longer restarts the resolver.
  # Copied, not the default symlink into /etc/static: activation then replaces
  # /etc/hosts itself, which AdGuard's watcher sees; the symlink never changes.
  # Rewrites are declared empty so the ones from before are dropped
  # (mutableSettings would otherwise keep them).
  services.adguardhome.settings.filtering.rewrites = [ ];
  environment.etc.hosts.mode = "0644";
  networking.hosts.${lanAddress} = names;

  security.acme = {
    acceptTerms = true;
    defaults.email = "salehtl@icloud.com";
    certs.${zone} = {
      domain = "*.${zone}";
      dnsProvider = "cloudflare";
      credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets."acme/cloudflare_token".path;
      group = config.services.nginx.group;
    };
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    defaultListen = [
      {
        addr = lanAddress;
        port = 443;
        ssl = true;
      }
    ];
    virtualHosts = lib.recursiveUpdate (
      vhosts
      // {
        # Unknown names get the TLS handshake refused rather than whichever
        # vhost nginx would otherwise pick first.
        "_" = {
          default = true;
          rejectSSL = true;
        };
      }
    ) (lib.genAttrs gatedNames (_: tailnetGate));
  };

  # Identifies the callers of gatedNames; see grafanaVhost and tailnetGate.
  services.nginx.tailscaleAuth = {
    enable = true;
    virtualHosts = gatedNames;
  };

  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # Interface-scoped, so the global allowedTCPPorts stays [ 22 ]. tailscale0
  # is where the subnet route lands. (tailscaled's own ts-input chain already
  # accepts all of tailscale0 ahead of these rules; declared anyway so the
  # firewall states the intent and survives a netfilter-mode change.)
  networking.firewall.interfaces = {
    ${lanInterface}.allowedTCPPorts = [ 443 ];
    tailscale0.allowedTCPPorts = [ 443 ];
  };

  # Appended to base.nix's [ "--ssh" ]; tailscaled-set applies the list with
  # `tailscale set` on every start, so this is the whole route config.
  services.tailscale.extraSetFlags = [ "--advertise-routes=${lanAddress}/32" ];

  # Every app is reached through this proxy, so nothing may use `tailscale
  # serve`: it would be a second route around tailscale-nginx-auth. tailscaled
  # keeps serve config in its own state, outside this flake, so clear it at
  # every boot. (On 2026-10-07 the per-app serve units were removed; their
  # three preStops raced, and ledger's lost with "etag mismatch", leaving its
  # mapping behind until this ran.)
  systemd.services.tailscale-serve-reset = {
    description = "Clear tailscale serve config (all ingress is the LAN proxy)";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.tailscale.package ];
    # tailscaled answers before it has a netmap after a cold start (boot, or a
    # lock bump restarting it alongside this unit), and `serve reset` then
    # fails with "netMap is nil". Retry inside the run: a Restart= loop left
    # the unit in auto-restart, which switch-to-configuration counts as failed.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 150;
    };
    script = ''
      for _ in $(seq 60); do
        tailscale serve reset 2>/dev/null && exit 0
        sleep 2
      done
      tailscale serve reset
    '';
  };

  # Re-runs on every boot and whenever the name list changes. Transient API or
  # network errors are retried inside the run (curl, lan-proxy-dns.sh); what is
  # left is a real problem (a hand-made record at a served name, a rotated
  # token), mailed once. No Restart= loop: a unit sitting in auto-restart made
  # every activation, the 04:00 upgrade included, report failure.
  systemd.services.lan-proxy-dns = {
    description = "Sync kakapo's public A records in Cloudflare DNS";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    environment = {
      ZONE = zone;
      ADDRESS = lanAddress;
      NAMES = lib.concatStringsSep " " names;
      # Prefix-matched, so records created under earlier comment texts are
      # still recognised as kakapo's.
      TAG = "Managed by github:salehtl/kakapo";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Never hold up an activation for long on a stalled API.
      TimeoutStartSec = 300;
      DynamicUser = true;
      LoadCredential = "token:${config.sops.secrets."acme/cloudflare_token".path}";
      ExecStart = lib.getExe dnsSync;
    };
  };

  assertions = [
    {
      assertion = !(lib.elem 443 config.networking.firewall.allowedTCPPorts);
      message = "Port 443 is in the global networking.firewall.allowedTCPPorts. The LAN proxy must be reachable on ${lanInterface} and tailscale0 only; use networking.firewall.interfaces.<iface> instead.";
    }
    {
      assertion = !(lib.elem grafanaPort (lib.attrValues proxied));
      message = "Grafana is in `proxied`, which forwards without authentication. Grafana trusts the Tailscale-User-Login header from loopback (auth.proxy), and nginx connects from loopback, so anyone on the LAN would be one forged header from admin. grafana.salehtl.com has its own vhost (grafanaVhost) behind tailscale-nginx-auth.";
    }
    {
      # tailscaleAuth guards only `location /`, so a gated vhost may have
      # nothing else: no extra location, no server-level `location`, and the
      # tailnet check on /auth.
      assertion =
        config.services.nginx.tailscaleAuth.enable
        && lib.all (
          name:
          let
            v = config.services.nginx.virtualHosts.${name};
          in
          lib.elem name config.services.nginx.tailscaleAuth.virtualHosts
          &&
            lib.attrNames v.locations == [
              "/"
              "/auth"
            ]
          && lib.hasInfix "auth_request /auth;" v.locations."/".extraConfig
          && lib.hasInfix ''Expected-Tailnet "${tailnetName}"'' v.locations."/auth".extraConfig
          && !(lib.hasInfix "location" v.extraConfig)
        ) gatedNames;
      message = "A gated name (${lib.concatStringsSep ", " gatedNames}) is not fully behind tailscale-nginx-auth: it is missing from tailscaleAuth.virtualHosts, lacks the Expected-Tailnet check on /auth, or has a location outside the gated `/` (tailscaleAuth guards only `/`). Grafana hands out admin from a header, ledger has no login, and T3 Code runs agents as saleh, who has passwordless sudo.";
    }
    {
      # No other vhost may reach a gated app's port: not through `proxied`, a
      # lanUpstreams URL, serverExtra, or a location added by another module.
      assertion = lib.all (
        name:
        let
          v = config.services.nginx.virtualHosts.${name};
          text = lib.concatStringsSep "\n" (
            [ v.extraConfig ]
            ++ lib.concatMap (l: [
              (if l.proxyPass == null then "" else l.proxyPass)
              l.extraConfig
            ]) (lib.attrValues v.locations)
          );
        in
        !(lib.any (
          port:
          lib.any (line: builtins.match ".*:${toString port}([^0-9].*)?" line != null) (
            lib.splitString "\n" text
          )
        ) gatedPorts)
      ) (lib.subtractLists gatedNames (lib.attrNames config.services.nginx.virtualHosts));
      message = "An ungated nginx vhost proxies to a gated app's port (${
        lib.concatMapStringsSep ", " toString gatedPorts
      }). That route skips tailscale-nginx-auth and exposes it to the plain LAN; gated apps belong in `tailnetOnly` (or grafanaVhost) only.";
    }
    {
      assertion = !(lib.elem ledgerPort (lib.attrValues proxied));
      message = "ledger is in `proxied`, which forwards without authentication. It has no login, holds financial data and is tailnet-only by policy (modules/services/ledger.nix); keep it in `tailnetOnly`.";
    }
  ];
}

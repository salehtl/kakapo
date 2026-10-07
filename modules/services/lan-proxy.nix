# <service>.salehtl.com for every device in the house, not just the tailnet --
# TVs, guests' phones, anything on the LAN -- and for tailnet devices anywhere.
#
# Names:   One name per service directly under salehtl.com (plex.salehtl.com,
#          not plex.home.salehtl.com). Never a DNS wildcard: *.salehtl.com
#          would point every unlisted name on the domain, including any future
#          public site, at a LAN address. The names come from `proxied` below
#          and are published in three places that always agree:
#            - AdGuard rewrites, so the LAN resolves them with the internet down.
#            - Public A records in Cloudflare, kept exact by lan-proxy-dns, for
#              everything that does not ask AdGuard: tailnet devices away from
#              home (the tailnet has no global nameserver, only MagicDNS) and
#              devices at home using iCloud Private Relay or their own DoH. They
#              reveal only a private address.
#            - /etc/hosts, because kakapo never resolves through its own AdGuard.
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

  # name -> extra nginx server directives, for apps the defaults don't fit.
  # name -> 127.0.0.1 port, reachable only by tailnet devices: behind
  # tailscale-nginx-auth like Grafana, but without the identity header. For
  # apps with their own login that are too dangerous for the plain LAN.
  tailnetOnly = {
    # T3 Code, when saleh has started it; agents run as saleh, who has
    # passwordless sudo (modules/services/t3code.nix).
    t3 = 3773;
  };
  tailnetOnlyNames = map (name: "${name}.${zone}") (lib.attrNames tailnetOnly);

  serverExtra = {
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
  // lib.mapAttrs' (name: url: lib.nameValuePair "${name}.${zone}" (proxyVhost url)) lanUpstreams;

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
  services.adguardhome.settings.filtering.rewrites = map (name: {
    domain = name;
    answer = lanAddress;
    # Defaults to false in AdGuard's schema: omit it and the rewrite is
    # silently inert.
    enabled = true;
  }) names;

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
    virtualHosts = vhosts // {
      # Unknown names get the TLS handshake refused rather than whichever
      # vhost nginx would otherwise pick first.
      "_" = {
        default = true;
        rejectSSL = true;
      };
    };
  };

  # Identifies grafana.salehtl.com's callers; see grafanaVhost. expectedTailnet
  # also refuses devices shared into the tailnet from another one.
  services.nginx.tailscaleAuth = {
    enable = true;
    expectedTailnet = "marmoset-paradise.ts.net";
    virtualHosts = [ "grafana.${zone}" ] ++ tailnetOnlyNames;
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

  # Re-runs on every boot and whenever the name list changes.
  systemd.services.lan-proxy-dns = {
    description = "Sync kakapo's public A records in Cloudflare DNS";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      ZONE = zone;
      ADDRESS = lanAddress;
      NAMES = lib.concatStringsSep " " names;
      # Prefix-matched, so records created under earlier comment texts are
      # still recognised as kakapo's.
      TAG = "Managed by github:salehtl/kakapo";
    };
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 300;
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
      assertion =
        config.services.nginx.tailscaleAuth.enable
        && config.services.nginx.tailscaleAuth.expectedTailnet != ""
        && lib.elem "grafana.${zone}" config.services.nginx.tailscaleAuth.virtualHosts;
      message = "grafana.${zone} is served without tailscale-nginx-auth. Its vhost sets Tailscale-User-Login from $auth_user, so without the auth_request that header is empty or forgeable and Grafana's auth.proxy would hand out admin. Keep it in services.nginx.tailscaleAuth.virtualHosts with expectedTailnet set.";
    }
    {
      assertion =
        lib.all (name: lib.elem name config.services.nginx.tailscaleAuth.virtualHosts) tailnetOnlyNames
        && !(lib.elem 3773 (lib.attrValues proxied));
      message = "A tailnetOnly name (${lib.concatStringsSep ", " tailnetOnlyNames}) is served without tailscale-nginx-auth, or T3 Code's port is in `proxied`. T3 Code runs agents as saleh, who has passwordless sudo: on the plain LAN it would be one leaked pairing token from root.";
    }
    {
      assertion = !(lib.elem ledgerPort (lib.attrValues proxied));
      message = "ledger is proxied on the LAN. It holds financial data and is tailnet-only by policy (modules/services/ledger.nix); keep it on tailscale serve.";
    }
  ];
}

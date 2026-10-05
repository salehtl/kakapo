# *.home.salehtl.com: names for kakapo's services that work on every device in
# the house, not just the tailnet -- TVs, guests' phones, anything on the LAN.
#
# DNS:     AdGuard (modules/services/adguard.nix) answers
#          *.home.salehtl.com -> 10.0.0.215 for the LAN and the tailnet.
#          Nothing is published in public DNS. kakapo itself never resolves
#          through its own AdGuard, so it gets the same names from /etc/hosts.
# TLS:     One wildcard certificate from Let's Encrypt via the DNS-01 challenge
#          on Cloudflare, so nothing has to be reachable from the internet. A
#          wildcard also keeps service names out of Certificate Transparency
#          logs. Token: secrets/acme.yaml (Zone:DNS:Edit + Zone:Read on
#          salehtl.com only).
# Ingress: nginx on 10.0.0.215:443, firewall-scoped to the LAN NIC. This is the
#          second exception to "services are reached through tailscale serve"
#          (the first is AdGuard's :53): tailscale serve can only present the
#          *.ts.net certificate and only reaches tailnet devices, and the point
#          here is devices that are not on the tailnet. Approved by Saleh on
#          2026-10-05. Port 80 stays closed: DNS-01 needs no HTTP listener.
#
#          nginx binds the LAN address, not 0.0.0.0, because tailscaled already
#          listens on the tailnet address's :443 for `tailscale serve`, and a
#          wildcard bind would collide with it. 10.0.0.215 is a fixed DHCP
#          reservation in UniFi (see CLAUDE.md); ip_nonlocal_bind lets nginx
#          start before NetworkManager has brought the address up.
#
# Adding a service: add `<name> = <port>;` to `proxied` below. It becomes
# https://<name>.home.salehtl.com, proxied to 127.0.0.1:<port>.
{ config, lib, ... }:
let
  domain = "home.salehtl.com";
  lanAddress = "10.0.0.215";
  lanInterface = "enp4s0"; # same NIC as modules/services/adguard.nix

  # name -> 127.0.0.1 port. Never Grafana or ledger; see the assertions.
  proxied = { };

  grafanaPort = config.services.grafana.settings.server.http_port;
  ledgerPort = lib.toInt (
    lib.last (lib.splitString ":" config.services.ledger.settings.server.listen)
  );

  vhost =
    extra:
    {
      useACMEHost = domain;
      onlySSL = true;
    }
    // extra;

  proxyVhost =
    port:
    vhost {
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        proxyWebsockets = true;
        # Grafana's auth.proxy trusts these headers from loopback, which is
        # where nginx connects from. Never forward a client's copy.
        extraConfig = ''
          proxy_set_header Tailscale-User-Login "";
          proxy_set_header Tailscale-User-Name "";
        '';
      };
    };

  vhosts = {
    # Landing page, and the name to test the whole chain with.
    "kakapo.${domain}" = vhost {
      locations."/".extraConfig = ''
        default_type text/plain;
        return 200 "kakapo\n";
      '';
    };
  }
  // lib.mapAttrs' (name: port: lib.nameValuePair "${name}.${domain}" (proxyVhost port)) proxied;
in
{
  services.adguardhome.settings.filtering.rewrites = [
    {
      domain = "*.${domain}";
      answer = lanAddress;
      # Defaults to false in AdGuard's schema: omit it and the rewrite is
      # silently inert.
      enabled = true;
    }
  ];

  # kakapo resolves through 1.1.1.2, never its own AdGuard (see adguard.nix),
  # so it needs its own copy of the names. /etc/hosts has no wildcards, hence
  # one entry per vhost.
  networking.hosts.${lanAddress} = lib.attrNames vhosts;

  security.acme = {
    acceptTerms = true;
    defaults.email = "salehtl@icloud.com";
    certs.${domain} = {
      domain = "*.${domain}";
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

  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # Interface-scoped, so the global allowedTCPPorts stays [ 22 ].
  networking.firewall.interfaces.${lanInterface}.allowedTCPPorts = [ 443 ];

  assertions = [
    {
      assertion = !(lib.elem 443 config.networking.firewall.allowedTCPPorts);
      message = "Port 443 is in the global networking.firewall.allowedTCPPorts. The home-domain proxy must be reachable on ${lanInterface} only; use networking.firewall.interfaces.${lanInterface} instead.";
    }
    {
      assertion = !(lib.elem grafanaPort (lib.attrValues proxied));
      message = "Grafana is proxied on *.${domain}. Grafana trusts the Tailscale-User-Login header from loopback (auth.proxy), and nginx connects from loopback, so anyone on the LAN would be one forged header from admin. Keep Grafana on tailscale serve.";
    }
    {
      assertion = !(lib.elem ledgerPort (lib.attrValues proxied));
      message = "ledger is proxied on *.${domain}. It holds financial data and is tailnet-only by policy (modules/services/ledger.nix); keep it on tailscale serve.";
    }
  ];
}

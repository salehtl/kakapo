# *.home.salehtl.com: names for kakapo's services that work on every device in
# the house, not just the tailnet -- TVs, guests' phones, anything on the LAN.
#
# DNS:     *.home.salehtl.com -> 10.0.0.215, answered in two places that agree:
#            - AdGuard (modules/services/adguard.nix) rewrites it for the LAN,
#              so names keep working with the internet down.
#            - A public wildcard A record in Cloudflare, kept in place by the
#              home-domain-dns unit below, for everything that does not ask
#              AdGuard: tailnet devices away from home (the tailnet has no
#              global nameserver, only MagicDNS) and devices at home using
#              iCloud Private Relay or their own DoH. It reveals only that
#              home.salehtl.com points at a private address; the wildcard
#              keeps service names out of it.
#          kakapo itself never resolves through its own AdGuard, so it gets the
#          same names from /etc/hosts.
# Away:    kakapo advertises 10.0.0.215/32 as a Tailscale subnet route, so a
#          tailnet device anywhere reaches the LAN address through the tunnel.
#          A route to the host's own address is local delivery, not
#          forwarding. It needs a one-time approval in the Tailscale admin
#          console (Machines -> kakapo -> Edit route settings), which is
#          invisible from this flake. Linux clients also need
#          `--accept-routes`; macOS, iOS, Android and Windows accept routes by
#          default. The tailnet policy is allow-all, so no ACL change.
# TLS:     One wildcard certificate from Let's Encrypt via the DNS-01 challenge
#          on Cloudflare, so nothing has to be reachable from the internet. A
#          wildcard also keeps service names out of Certificate Transparency
#          logs. Token: secrets/acme.yaml (Zone:DNS:Edit + Zone:Read on
#          salehtl.com only).
# Ingress: nginx on 10.0.0.215:443, firewall-scoped to the LAN NIC and
#          tailscale0 (the subnet route arrives there). This is the
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
{
  config,
  lib,
  pkgs,
  ...
}:
let
  zone = "salehtl.com";
  domain = "home.${zone}";
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

  # Reconciles the public wildcard record: creates it if missing, corrects it
  # if it drifted, and fails loudly if there is more than one. Re-runs on
  # every boot and whenever this unit changes.
  systemd.services.home-domain-dns =
    let
      record = "*.${domain}";
    in
    {
      description = "Point ${record} at ${lanAddress} in Cloudflare DNS";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.curl
        pkgs.jq
      ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        DynamicUser = true;
        LoadCredential = "token:${config.sops.secrets."acme/cloudflare_token".path}";
      };
      # The token reaches curl through --config on a pipe, never argv.
      script = ''
        set -euo pipefail
        api=https://api.cloudflare.com/client/v4
        cf() {
          curl -fsS --config <(printf 'header = "Authorization: Bearer %s"\n' "$(< "$CREDENTIALS_DIRECTORY/token")") \
            -H 'Content-Type: application/json' "$@"
        }

        zone_id=$(cf --get "$api/zones" --data-urlencode "name=${zone}" | jq -er '.result[0].id')
        existing=$(cf --get "$api/zones/$zone_id/dns_records" \
          --data-urlencode "type=A" --data-urlencode "name=${record}" | jq -c '.result')
        want=$(jq -nc '{type: "A", name: "${record}", content: "${lanAddress}", ttl: 300,
          proxied: false, comment: "Managed by github:salehtl/kakapo home-domain.nix"}')

        case $(jq length <<<"$existing") in
          0)
            cf -X POST "$api/zones/$zone_id/dns_records" --data "$want" >/dev/null
            echo "created ${record} -> ${lanAddress}" ;;
          1)
            if jq -e '.[0].content == "${lanAddress}" and .[0].proxied == false' <<<"$existing" >/dev/null; then
              echo "${record} already -> ${lanAddress}"
            else
              id=$(jq -r '.[0].id' <<<"$existing")
              cf -X PUT "$api/zones/$zone_id/dns_records/$id" --data "$want" >/dev/null
              echo "corrected ${record} -> ${lanAddress}"
            fi ;;
          *)
            echo "more than one A record for ${record}; refusing to guess which to keep" >&2
            exit 1 ;;
        esac
      '';
    };

  assertions = [
    {
      assertion = !(lib.elem 443 config.networking.firewall.allowedTCPPorts);
      message = "Port 443 is in the global networking.firewall.allowedTCPPorts. The home-domain proxy must be reachable on ${lanInterface} and tailscale0 only; use networking.firewall.interfaces.<iface> instead.";
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

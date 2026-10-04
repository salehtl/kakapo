# AdGuard Home: network-wide DNS filtering with HaGeZi's blocklists, for the
# tailnet and the home LAN. Replaces the Home Assistant resolver at 10.0.0.10,
# which stopped answering on :53 on 2026-10-04.
#
# State:   /var/lib/AdGuardHome/AdGuardHome.yaml (DynamicUser, 0600)
#          Filter list copies live beside it and refresh on AdGuard's own timer.
# Ingress: Web UI is tailnet only, https://kakapo.<tailnet>.ts.net:10000/.
#          DNS is :53 on the tailnet and the LAN -- see "Why :53 is open" below.
# Login:   No `users` block is declared on purpose. A bcrypt hash in
#          `settings` would land world-readable in the Nix store, so the
#          password is set once through the web UI and persists in the state
#          directory via `mutableSettings`. Same shape as Grafana's
#          host-generated secret_key. Until it is set the UI is
#          unauthenticated to the tailnet, so set it on first boot.
#
# Why :53 is open, when every other service here binds 127.0.0.1:
#   `tailscale serve` is an HTTPS reverse proxy. It cannot carry UDP, and it
#   only accepts 443/8443/10000 -- so there is no way to reach a resolver
#   through it. A DNS server that only listens on loopback filters nothing but
#   kakapo's own queries. The port is therefore open, but never globally:
#     1. Firewall rules are scoped to tailscale0 and the LAN NIC, so :53 is
#        unreachable from anywhere `networking.firewall.allowedTCPPorts` would
#        expose it. The global list stays [ 22 ].
#     2. `dns.allowed_clients` restricts answers to the tailnet CGNAT range and
#        the LAN /24, independently of the firewall. An open resolver is an
#        amplification source; this holds even if a firewall rule regresses.
#     3. `ratelimit` caps per-client QPS.
#   bind_hosts is 0.0.0.0 rather than the three literal addresses because the
#   LAN address comes from DHCP: pinning 10.0.0.215 here would silently take
#   DNS down for the whole house on a lease change. The interface-scoped
#   firewall is the control that matters and is immune to that.
{
  config,
  lib,
  ...
}:
let
  servePort = 10000; # tailscale serve allows 443 (ledger), 8443 (Grafana), 10000
  uiPort = 3001; # not 3000: Grafana has it (modules/services/monitoring.nix)

  lanInterface = "enp4s0"; # the igb NIC from hosts/kakapo/hardware.nix
  lanCidr = "10.0.0.0/24";
  lanGateway = "10.0.0.1";
  tailnetCidr = "100.64.0.0/10"; # Tailscale's CGNAT range
  tailnetDomain = "marmoset-paradise.ts.net";
  magicDns = "100.100.100.100";

  # HaGeZi's lists, in AdBlock syntax, pinned to the @latest jsDelivr mirror so
  # AdGuard's own 24h refresh picks up upstream changes without a rebuild.
  hagezi = path: "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/${path}";

  # AdGuard requires a unique integer id per filter. Numbered from 1001 to stay
  # clear of the ids in AdGuard's own registry of known filters.
  mkFilters = lib.imap0 (
    i:
    { name, file }:
    {
      inherit name;
      id = 1001 + i;
      url = hagezi file;
      enabled = true;
    }
  );
in
{
  services.adguardhome = {
    enable = true;

    # Web UI only. DNS binding is dns.bind_hosts below.
    host = "127.0.0.1";
    port = uiPort;

    # Leave this false. It would add the UI port to the *global*
    # allowedTCPPorts, which is exactly what this host does not do.
    openFirewall = false;

    # Keeps the admin password (and any ad-hoc UI tweak to a key not declared
    # here) across restarts. Everything declared below is still reapplied on
    # every start, so Nix stays authoritative for the filter set.
    mutableSettings = true;

    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        # DoH, so resolution never depends on the LAN resolver this service is
        # replacing, and never loops back through MagicDNS into AdGuard.
        upstream_dns = [
          "https://cloudflare-dns.com/dns-query"
          "https://dns.quad9.net/dns-query"
          # Split DNS: tailnet names stay with MagicDNS, router-local names
          # stay with the router. Without these, putting the house on AdGuard
          # would break both. The reverse zone is scoped to 10.0.0.0/24 rather
          # than all of in-addr.arpa, which would send public PTR lookups to
          # the router and get SERVFAIL.
          "[/${tailnetDomain}/]${magicDns}"
          "[/routerlocal/]${lanGateway}"
          "[/0.0.10.in-addr.arpa/]${lanGateway}"
        ];
        # Plain IPs: needed to resolve the DoH hostnames above.
        bootstrap_dns = [
          "1.1.1.1"
          "9.9.9.9"
          "2606:4700:4700::1111"
        ];
        upstream_mode = "load_balance";

        # Defence in depth against becoming an open resolver; see header.
        allowed_clients = [
          "127.0.0.1"
          tailnetCidr
          lanCidr
        ];
        ratelimit = 50;

        enable_dnssec = true;
        cache_size = 67108864; # 64 MiB
        cache_ttl_min = 60;
      };

      filters = mkFilters [
        {
          name = "HaGeZi's Multi NORMAL";
          file = "multi.txt";
        }
        {
          name = "HaGeZi's Threat Intelligence Feeds Medium";
          file = "tif.medium.txt";
        }
        {
          name = "HaGeZi's Badware Hoster";
          file = "hoster.txt";
        }
        {
          name = "HaGeZi's Pop-Up Ads";
          file = "popupads.txt";
        }
      ];

      # Unblocks affiliate/tracking referral links that the lists above catch
      # but that break order confirmations and search results.
      whitelist_filters = [
        {
          name = "HaGeZi's Allowlist Referral";
          id = 2001;
          url = hagezi "whitelist-referral.txt";
          enabled = true;
        }
      ];
    };
  };

  # kakapo must not resolve through its own AdGuard. Once the LAN's DHCP hands
  # out this host as the resolver, a dead AdGuard would otherwise take the
  # 04:00 `nixos-upgrade` with it -- github.com stops resolving and the failure
  # is silent, the same shape as the four-month lock outage.
  #
  # Nothing is set here because `hosts/kakapo/default.nix` already pins
  # 1.1.1.2/1.0.0.2 with `networkmanager.dns = "none"` (387d991). That is the
  # property this service depends on, so the assertion below fails the build if
  # it is ever removed -- do not re-add `insertNameservers` as a substitute: it
  # only puts entries *first* and leaves the DHCP-supplied resolver underneath.

  # Interface-scoped, so the global allowedTCPPorts stays [ 22 ]. UDP is the
  # real resolver path; TCP covers truncated answers and zone-transfer-sized
  # replies, and both must agree or large responses fail intermittently.
  networking.firewall.interfaces =
    let
      dns = {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 53 ];
      };
    in
    {
      tailscale0 = dns;
      ${lanInterface} = dns;
    };

  # Same pattern as ledger-tailscale-serve and grafana-tailscale-serve.
  systemd.services.adguardhome-tailscale-serve = {
    description = "Serve the AdGuard Home UI to the tailnet over HTTPS";
    after = [
      "tailscaled.service"
      "adguardhome.service"
    ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.tailscale.package ];
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 60;
    };
    script = "tailscale serve --bg --https=${toString servePort} http://127.0.0.1:${toString uiPort}";
    preStop = "tailscale serve --https=${toString servePort} off";
  };

  assertions = [
    {
      # modules/services/adguard.nix depends on the host resolving
      # independently of this service; see the note above.
      assertion = config.networking.networkmanager.dns == "none" && config.networking.nameservers != [ ];
      message = "kakapo would resolve through its own AdGuard: networking.nameservers is unset or NetworkManager still manages resolv.conf, so DHCP can hand this host itself as its resolver. A dead AdGuard then breaks the 04:00 nixos-upgrade silently. Keep the 1.1.1.2/1.0.0.2 pin in hosts/kakapo/default.nix.";
    }
    {
      assertion = config.services.adguardhome.port != config.services.grafana.settings.server.http_port;
      message = "AdGuard Home and Grafana are both bound to 127.0.0.1:${toString uiPort}. One of them will fail to start, and which one is a race.";
    }
    {
      assertion = !(lib.elem 53 config.networking.firewall.allowedTCPPorts);
      message = "Port 53 is in the global networking.firewall.allowedTCPPorts. AdGuard Home must be reachable on tailscale0 and ${lanInterface} only -- a globally open resolver is a DNS amplification source. Use networking.firewall.interfaces.<iface> instead.";
    }
    {
      assertion = config.services.adguardhome.settings.dns.allowed_clients or [ ] != [ ];
      message = "services.adguardhome.settings.dns.allowed_clients is empty, which makes this an open resolver for anything that reaches :53. It is the control that survives a firewall regression; keep it populated.";
    }
  ];

  # No Prometheus scrape job here on purpose: AdGuard Home 0.107.79 ships no
  # /metrics endpoint (verified -- the binary links no prometheus client), so a
  # scrapeConfig pointed at it would sit permanently red on the Grafana
  # dashboard. Monitoring it would need a separate adguard_exporter sidecar.
  #
  # Note also that the UI is reached through `tailscale serve`, which connects
  # from loopback, so AdGuard attributes every *UI-side* query log entry to
  # 127.0.0.1. Real DNS clients hit :53 directly and are logged correctly.
}

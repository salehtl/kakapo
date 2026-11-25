# AdGuard Home: network-wide DNS filtering with HaGeZi's blocklists, for the
# tailnet and the home LAN.
#
# State:   /var/lib/AdGuardHome/AdGuardHome.yaml (DynamicUser, 0600), with the
#          filter list copies beside it.
# Ingress: Web UI at https://adguard.salehtl.com, LAN and tailnet
#          (modules/services/lan-proxy.nix). DNS is :53 on the tailnet and the
#          LAN: see "Why :53 is open" below.
# Login:   None, by Saleh's choice: the UI is open to anyone on the LAN and
#          tailnet. If one is ever wanted, never put the bcrypt hash in
#          `settings` (world-readable Nix store), and never add a step to
#          adguardhome's own preStart: its seccomp sandbox kills it and the
#          house loses DNS. Use a separate root oneshot that adguardhome only
#          *wants*.
#
# Why :53 is open, when every other service here binds 127.0.0.1: a resolver
# on loopback filters nothing but kakapo's own queries. Never globally:
#   1. The firewall opens :53 only on tailscale0 and the LAN NIC. The global
#      allowedTCPPorts stays [ 22 ].
#   2. `dns.allowed_clients` restricts answers to the tailnet, the LAN /24 and
#      the IoT VLAN, independently of the firewall: an open resolver is an
#      amplification source.
#   3. `ratelimit` caps per-client QPS.
# bind_hosts is 0.0.0.0, not the literal addresses: the LAN address comes from
# DHCP, and pinning it would take DNS down for the house on a lease change.
#
# Outside the flake: UniFi hands out 10.0.0.215 as DNS on the Default and IoT
# networks, with a fixed reservation for kakapo, so every device in the house
# resolves here. There is no secondary resolver on purpose: a non-filtering
# fallback would make filtering inconsistent. Guest stays on 1.1.1.3.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  uiPort = 3001; # not 3000: Grafana has it (modules/services/monitoring.nix)

  lanInterface = "enp4s0"; # the igb NIC from hosts/kakapo/hardware.nix
  lanCidr = "10.0.0.0/24";
  # IoT VLAN 30. UniFi hands it 10.0.0.215 as DNS and its firewall allows
  # IoT -> 10.0.0.215:53, so it must be in allowed_clients or its queries are
  # silently dropped. Its packets arrive on the LAN NIC, routed by the gateway.
  iotCidr = "192.168.30.0/24";
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

    # Never true: it adds the UI port to the global allowedTCPPorts.
    openFirewall = false;

    # Keeps ad-hoc UI settings across restarts. Everything declared below is
    # still reapplied on every start.
    mutableSettings = true;

    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        # DoH, so resolution never loops back through MagicDNS into AdGuard.
        upstream_dns = [
          "https://cloudflare-dns.com/dns-query"
          "https://dns.quad9.net/dns-query"
          # Split DNS: tailnet names stay with MagicDNS, router-local names
          # with the router.
          "[/${tailnetDomain}/]${magicDns}"
          "[/routerlocal/]${lanGateway}"
        ];
        # PTR lookups for private addresses go only to the router, which knows
        # its DHCP clients' names.
        local_ptr_upstreams = [ lanGateway ];
        # Plain IPs: needed to resolve the DoH hostnames above.
        bootstrap_dns = [
          "1.1.1.1"
          "9.9.9.9"
          "2606:4700:4700::1111"
        ];
        upstream_mode = "load_balance";

        # Defence in depth against becoming an open resolver; see the header.
        allowed_clients = [
          "127.0.0.1"
          tailnetCidr
          lanCidr
          iotCidr
        ];
        ratelimit = 50;
        # Per client. AdGuard's defaults (24 / 56) bucket a whole /24 together,
        # so one device's burst starves every other LAN client.
        ratelimit_subnet_len_ipv4 = 32;
        ratelimit_subnet_len_ipv6 = 128;

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

      # Unblocks referral links that the lists above catch but that break order
      # confirmations and search results.
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

  # Every minute. The query runs over `lo`, so it is paired with the parts of
  # the LAN path a loopback query skips: 10.0.0.215 on the LAN NIC and the rule
  # opening :53 there. Alerts (kakapo-alert, level fail) after two consecutive
  # failures and once on recovery; an undelivered alert is retried on the next
  # run. health-check leaves its `dns` check to this unit.
  systemd.services.dns-health = {
    description = "Check that AdGuard answers DNS for the house";
    path = [
      pkgs.dnsutils
      pkgs.gnugrep
      pkgs.coreutils
      pkgs.iproute2
      config.networking.firewall.package
      config.systemd.package
    ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "dns-health";
    };
    script = ''
      failing=/var/lib/dns-health/failing
      alerted=/var/lib/dns-health/alerted
      alert=${
        pkgs.callPackage ../../pkgs/kakapo-alert {
          inherit (config.networking) hostName;
          mailTo = "salehtl@icloud.com";
        }
      }/bin/kakapo-alert
      problem=
      if ! ip -4 -o addr show dev ${lanInterface} | grep -q ' 10\.0\.0\.215/'; then
        problem="10.0.0.215 is not on ${lanInterface}"
      elif ! iptables -C nixos-fw -i ${lanInterface} -p udp --dport 53 -j nixos-fw-accept 2>/dev/null; then
        problem="the firewall does not open udp/53 on ${lanInterface}"
      elif ! dig +short +time=3 +tries=2 @10.0.0.215 one.one.one.one A | grep -q '^[0-9]'; then
        problem="AdGuard on 10.0.0.215 did not answer"
      fi
      if [ -z "$problem" ]; then
        rm -f "$failing"
        if [ -e "$alerted" ]; then
          if echo "AdGuard on 10.0.0.215 answers the house again." | $alert ok dns "DNS answers again" --mail; then
            rm "$alerted"
          else
            echo "recovery alert not delivered; retrying next run" >&2
          fi
        fi
      else
        n=$(( $(cat "$failing" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$failing"
        echo "$problem (failure $n in a row)" >&2
        if [ "$n" -ge 2 ] && [ ! -e "$alerted" ]; then
          if $alert fail dns "DNS is down for the house" <<EOF
      $problem, $n checks in a row.

      Fastest recovery: sudo systemctl restart adguardhome
      Or set the UniFi DHCP DNS back to 1.1.1.1 (Settings > Networks > Default).

      $(systemctl status --no-pager adguardhome 2>&1 | head -20)
      EOF
          then
            touch "$alerted"
          else
            echo "alert not delivered; retrying next run" >&2
          fi
        fi
      fi
    '';
  };
  systemd.timers.dns-health = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
    };
  };
  # kakapo must not resolve through its own AdGuard: a dead AdGuard would
  # silently take the 04:00 upgrade with it. hosts/kakapo/default.nix pins
  # 1.1.1.2/1.0.0.2 with `networkmanager.dns = "none"`, and an assertion below
  # fails the build if that goes. Do not use `insertNameservers` instead: it
  # leaves the DHCP-supplied resolver underneath.

  # Interface-scoped, so the global allowedTCPPorts stays [ 22 ]. TCP covers
  # truncated answers; without it large responses fail intermittently.
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

  assertions = [
    {
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

  # No Prometheus scrape job: AdGuard Home ships no /metrics endpoint.
  #
  # The UI is reached through the LAN proxy, so AdGuard logs UI-side queries
  # as 127.0.0.1. Real DNS clients hit :53 directly and are logged correctly.
}

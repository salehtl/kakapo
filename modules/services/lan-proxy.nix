# <service>.salehtl.com for every device in the house (TVs, guests' phones,
# anything on the LAN) and for tailnet devices anywhere.
#
# Names:   One name per service directly under salehtl.com. Never a DNS
#          wildcard: *.salehtl.com would point every unlisted name, including
#          any future public site, at a LAN address. The names come from the
#          lists below and are published in two places that always agree:
#            - Public A records in Cloudflare, kept exact by lan-proxy-dns, for
#              whatever does not ask AdGuard: tailnet devices away from home
#              and devices using iCloud Private Relay or their own DoH. They
#              reveal only a private address.
#            - /etc/hosts, for kakapo itself and for the LAN: AdGuard answers
#              from it (hostsfile_enabled), also with the internet down. Not
#              AdGuard rewrites: a change to those restarts the house's
#              resolver.
# TLS:     One wildcard certificate, *.salehtl.com, from Let's Encrypt via
#          DNS-01 on Cloudflare: nothing has to be reachable from the internet,
#          and service names stay out of Certificate Transparency logs.
#          Token: secrets/acme.yaml.
# Ingress: nginx on 10.0.0.215:443, firewall-scoped to the LAN NIC and
#          tailscale0. Port 80 stays closed. nginx binds the LAN address, not
#          0.0.0.0, which would collide with tailscaled on the tailnet
#          address's :443. ip_nonlocal_bind lets nginx start before
#          NetworkManager has brought the address up.
# Away:    kakapo advertises 10.0.0.215/32 as a Tailscale subnet route, so a
#          tailnet device anywhere reaches the LAN address through the tunnel.
#          Linux clients also need `--accept-routes`.
# Identity: the gated names (grafana and `tailnetOnly`) trust tailscale-nginx-
#          auth, which asks tailscaled who owns the connecting address. A
#          Tailscale identity is a USER, not a device: every untagged node
#          logged in as salehtl@github is "salehtl@github", and nginx-auth
#          refuses only tagged nodes. Two of those nodes are servers: kakapo
#          itself (tailscaled's WhoIs also answers for the machine's own
#          addresses) and homeassistant (runs third-party add-ons). Without
#          the controls below, any local process on kakapo could pose as Saleh
#          to nginx with
#            curl --interface <kakapo's 100.x> --resolve <name>:443:10.0.0.215
#          and anything on homeassistant could over the tailnet. Three
#          controls, all in this file:
#            1. `lan-proxy-out` (firewall below) resets every locally generated
#               TCP connection to :443 on one of this host's own addresses
#               whose source is a tailnet address, root included.
#               `lan-proxy-spoof-check` proves it every two minutes.
#            2. The Hasala console's vhost answers only `consoleDevices`.
#            3. STOPGAP: every gated vhost denies the tailnet addresses of
#               `servers` ahead of any allow (`untaggedDeny`).
#          Saleh's to do, in the Tailscale admin console: tag kakapo and
#          homeassistant (tag:server, which needs a `tagOwners` entry).
#          nginx-auth then refuses them on every gated name and control 3 can
#          go. A tagged node also leaves autogroup:self, which matters only if
#          the tailnet policy stops being allow-all.
#          KNOWN RESIDUAL RISK: these controls close the PROXY to local
#          processes, not the apps behind it. Only the console's port is
#          closed to them (`hasala-console-out` in the hasala module). Any
#          local user or service on kakapo can still reach Grafana on
#          127.0.0.1:3000 (it trusts a Tailscale-User-Login header from
#          loopback) and ntfy on 127.0.0.1:2586 (anonymous publishes).
#
# Adding a service: add `<name> = <port>;` to `proxied` below. It becomes
# https://<name>.salehtl.com, proxied to 127.0.0.1:<port>, and its DNS record
# appears on the next activation. Removing it deletes the record. A service on
# another LAN machine goes in `lanUpstreams` as `<name> = "http://<ip>:<port>";`.
#
# Outside the flake:
#   If the UniFi reservation for 10.0.0.215 changes, update lanAddress.
#   The subnet route must stay approved in the Tailscale admin console:
#     tailscale status --json | grep -A2 PrimaryRoutes   (lists 10.0.0.215/32)
#   If the tailnet policy stops being allow-all, the route needs an ACL entry.
#   Home Assistant must have forwarded headers on and trust 10.0.0.215; it
#   applies that only on a full restart.
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
  # Tailscale's address ranges.
  tailnetV4 = "100.64.0.0/10";
  tailnetV6 = "fd7a:115c:a1e0::/48";

  # The only devices the Hasala console's vhost answers: Saleh's own Mac and
  # iPhone, by tailnet address (`tailscale status`). NEVER add kakapo,
  # homeassistant or any other server or linux node (see `servers`). A
  # re-registered device gets a new address and sees 403 until it is updated
  # here. salehs-old-phone is left out until Saleh says it is still his. The
  # IPv6 entries matter only if nginx ever gains an IPv6 listener.
  consoleDevices = {
    rabbit = [
      "100.97.47.88"
      "fd7a:115c:a1e0::e3a:2f59"
    ];
    salehs-phone = [
      "100.96.130.97"
      "fd7a:115c:a1e0::f83a:8263"
    ];
  };
  # Untagged nodes logged in as salehtl@github that run other people's code or
  # services, by tailnet address (`tailscale status --json`). Never in
  # consoleDevices (asserted below); until they are tagged, every gated vhost
  # denies them (untaggedDeny).
  servers = {
    kakapo = [
      "100.98.60.126"
      "fd7a:115c:a1e0::1a3a:3c7e"
    ];
    homeassistant = [
      "100.65.241.104"
      "fd7a:115c:a1e0::9c01:f168"
    ];
  };
  serverAddresses = lib.concatLists (lib.attrValues servers);
  consoleAllow = lib.concatLists (lib.attrValues consoleDevices);

  # STOPGAP (control 3 in the header): remove this list, and its uses in
  # serverConfig and the gated-vhost assertion, once kakapo and homeassistant
  # are tagged. The first lines of every gated vhost's server config, so they
  # come before any allow and cover `/` without a location (a location with its
  # own allow or deny would replace them, which the assertion refuses).
  untaggedDeny = lib.concatMapStrings (ip: "deny ${ip};\n") serverAddresses;

  # For the access-rule assertions: the words of an nginx config snippet, so
  # `allow all;` has the word "allow" and Access-Control-Allow-Origin does not.
  hasDirective =
    names: text:
    lib.any (w: lib.elem w names) (lib.filter lib.isString (builtins.split "[[:space:];{}\"']+" text));
  # The http block, which every vhost inherits from. A `satisfy any` there
  # would let tailscale-nginx-auth alone admit a caller that consoleDevices or
  # untaggedDeny refuses.
  httpLevelConfig = lib.concatStringsSep "\n" [
    config.services.nginx.commonHttpConfig
    config.services.nginx.httpConfig
    config.services.nginx.appendHttpConfig
  ];

  # name -> 127.0.0.1 port, with no authentication added. Never Grafana (it
  # has its own vhost below).
  proxied = {
    # No login, by Saleh's choice: anyone on the LAN or tailnet can change
    # AdGuard's filtering.
    adguard = config.services.adguardhome.port;
    # Immich has its own accounts.
    photos = config.services.immich.port;
    # Gramps Web has its own accounts.
    gw = 5000;
    # Reading needs ntfy's login; publishing is refused here (serverExtra). On
    # the house network so alerts arrive while the phone's Tailscale is off.
    ntfy = 2586;
    # No login, by Saleh's choice: anyone on the home Wi-Fi can open the
    # uploaded room photos and make paid fal calls with no practical cap. Guest
    # stays out. Move it to `tailnetOnly` to gate it.
    midstudy = config.services.midstudy.webPort;
  };

  # name -> another machine on the LAN. Its traffic leaves kakapo from
  # lanAddress, so the upstream must trust 10.0.0.215 as a reverse proxy.
  lanUpstreams = {
    # Home Assistant Yellow. It must trust 10.0.0.215 as a reverse proxy, set in
    # its UI (Settings -> System -> Network; it ignores the http: block in
    # configuration.yaml) and applied on restart. Without it HA answers 400.
    home = "http://10.0.0.10:8123";
  };

  # name -> 127.0.0.1 port, reachable only by tailnet devices: behind
  # tailscale-nginx-auth like Grafana, but without the identity header. For
  # apps with their own login that are too dangerous for the plain LAN.
  tailnetOnly = {
    # Hasala's operator console (modules/services/hasala.nix). No login of its
    # own: it trusts X-Webauth-User and X-Webauth-Tailnet, which
    # tailscale-nginx-auth sets on this vhost, and the vhost answers only
    # consoleDevices (serverExtra.hasala). The Hasala API (8471) is public
    # through its own tunnel and must never be listed here, and the console
    # never goes on that tunnel.
    hasala = config.services.hasala.console.port;
    # T3 Code: coding agents with a shell on kakapo. Its own pairing token is
    # the second gate.
    t3 = 3773;
    # CLIProxyAPI. Its API key is the second gate; the management API is refused
    # here (serverExtra.cliproxy).
    cliproxy = config.services.cliproxyapi.settings.server.port;
  };
  tailnetOnlyNames = map (name: "${name}.${zone}") (lib.attrNames tailnetOnly);

  # Every name behind tailscale-nginx-auth, and the ports behind them.
  gatedNames = [ "grafana.${zone}" ] ++ tailnetOnlyNames;
  gatedPorts = [ grafanaPort ] ++ lib.attrValues tailnetOnly;
  # The tailnet as nginx-auth spells it, with the trailing dot. Without the dot
  # every request is 403.
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
    # HA backups upload as one request, often hundreds of MB.
    home = ''
      client_max_body_size 0;
    '';
    # Subscribers hold a stream open for hours. ntfy lets anonymous visitors
    # publish (kakapo's services do, on loopback), so the proxy refuses every
    # publish, including the GET forms. Server-level `if ... return` only, never
    # a location.
    ntfy = ''
      if ($request_method !~ ^(GET|HEAD)$) { return 403; }
      if ($uri ~ ^/[^/]+/(publish|send|trigger)$) { return 403; }
      proxy_buffering off;
      proxy_read_timeout 3h;
    '';
    # Family tree imports (GEDCOM, .gramps) and media arrive in one request.
    gw = ''
      client_max_body_size 500M;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
    # Saleh's own devices only (consoleDevices); everyone else gets 403.
    # serverConfig puts untaggedDeny ahead of these allows.
    hasala = lib.concatMapStrings (ip: "allow ${ip};\n") consoleAllow + "deny all;\n";
    # The agents' sessions are one long WebSocket each.
    t3 = ''
      client_max_body_size 100M;
      proxy_read_timeout 1d;
      proxy_send_timeout 1d;
    '';
    # Management (/v0, /v8 and the panel) only from kakapo itself. Responses
    # stream (SSE), and a long agent turn can take many minutes. Server-level
    # `if ... return` only, never a location.
    cliproxy = ''
      if ($uri ~* ^/+(v[0-9]+/+management|management\.html)) { return 403; }
      client_max_body_size 100M;
      proxy_buffering off;
      proxy_request_buffering off;
      proxy_read_timeout 1h;
      proxy_send_timeout 1h;
    '';
    # Furniture models (up to 200 MB) arrive in one request. Buffered, so
    # midstudy gets the Content-Length it requires; a render waits for fal
    # (up to 300 s) plus keep-room alignment (up to 180 s).
    midstudy = ''
      client_max_body_size 200M;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
    # Phone backups upload whole videos in one request: stream them through
    # instead of buffering to disk, and allow slow links.
    photos = ''
      client_max_body_size 50000M;
      proxy_request_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      send_timeout 600s;
    '';
  };

  # name -> extra nginx directives on the proxied `/` location.
  locationExtra = {
    # The console treats a Cloudflare header as a tunnel leak: it refuses the
    # request and turns /healthz to 503 for 24 hours. nginx sends it none, so a
    # tailnet peer cannot raise that alarm.
    hasala = ''
      proxy_set_header Cf-Connecting-Ip "";
      proxy_set_header Cf-Ray "";
      proxy_set_header Cf-Visitor "";
      proxy_set_header Cf-Ipcountry "";
      proxy_set_header Cdn-Loop "";
    '';
  };

  # On a gated name, untaggedDeny first, then its serverExtra.
  serverConfig =
    name:
    lib.optionalString (lib.elem "${name}.${zone}" gatedNames) untaggedDeny
    + (serverExtra.${name} or "");

  grafanaPort = config.services.grafana.settings.server.http_port;

  vhost =
    extra:
    {
      useACMEHost = zone;
      onlySSL = true;
    }
    // extra;

  proxyVhost =
    name: upstream:
    vhost {
      locations."/" = {
        proxyPass = upstream;
        proxyWebsockets = true;
        # Grafana's auth.proxy trusts these headers from loopback, which is
        # where nginx connects from. Never forward a client's copy.
        extraConfig = ''
          proxy_set_header Tailscale-User-Login "";
          proxy_set_header Tailscale-User-Name "";
        ''
        + (locationExtra.${name} or "");
      };
    };

  # Grafana logs in whoever its Tailscale-User-Login header names, trusting it
  # from loopback, which is where nginx connects from. So this vhost sets the
  # header from tailscaled's whois of the connecting address
  # (tailscale-nginx-auth); anything that fails whois gets 401. Never put
  # Grafana in `proxied`.
  grafanaVhost = vhost {
    extraConfig = serverConfig "grafana";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString grafanaPort}";
      proxyWebsockets = true;
      # $auth_user is the full login (salehtl@github); $auth_login is only the
      # part before the @.
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
      proxyVhost name "http://127.0.0.1:${toString port}" // { extraConfig = serverConfig name; }
    )
  ) (proxied // tailnetOnly)
  // lib.mapAttrs' (
    name: url:
    lib.nameValuePair "${name}.${zone}" (proxyVhost name url // { extraConfig = serverConfig name; })
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

  # What lan-proxy-out sees: locally generated TCP to :443 on one of this
  # host's own addresses. addrtype LOCAL rather than `-o lo`, because a socket
  # bound to tailscale0 routes 10.0.0.215 out of that interface. Forwarded
  # traffic (exit-node clients) never passes OUTPUT.
  outMatch = "-p tcp --dport 443 -m addrtype --dst-type LOCAL";
  # lan-proxy-out's one rule, per family; the spoof check `-C`s the same text.
  # Keep `-p tcp` in the rule itself: without it the kernel refuses
  # `--reject-with tcp-reset`, firewall-start stops before it attaches nixos-fw
  # to INPUT, and the host is left with no firewall.
  outReject = src: "-s ${src} -p tcp -j REJECT --reject-with tcp-reset";
  tsInterface = config.services.tailscale.interfaceName;

  # Control 1 in the header, tested the way it would be attacked: as a local
  # user that is neither root nor nginx, from kakapo's own tailnet address.
  spoofCheck = pkgs.writeShellApplication {
    name = "lan-proxy-spoof-check";
    runtimeInputs = [
      pkgs.curl
      pkgs.iproute2
      pkgs.util-linux
      pkgs.gawk
      pkgs.coreutils
      config.networking.firewall.package
    ];
    text = ''
      fail=0
      note() { echo "lan-proxy-spoof-check: $*" >&2; fail=1; }
      # curl as nobody: not root, and not nginx (the one user hasala-console-out
      # lets reach the console's port). -q: never read a .curlrc.
      as_nobody() { setpriv --reuid=nobody --regid=nogroup --clear-groups --inh-caps=-all curl -q "$@"; }

      # 1. The rules are loaded. nginx has no IPv6 listener, so the IPv6 twin
      #    can only be checked this way.
      iptables -w -C OUTPUT ${outMatch} -j lan-proxy-out 2>/dev/null \
        || note "iptables OUTPUT has no jump to lan-proxy-out"
      iptables -w -C lan-proxy-out ${outReject tailnetV4} 2>/dev/null \
        || note "lan-proxy-out does not reset ${tailnetV4}"
      ip6tables -w -C OUTPUT ${outMatch} -j lan-proxy-out 2>/dev/null \
        || note "ip6tables OUTPUT has no jump to lan-proxy-out"
      ip6tables -w -C lan-proxy-out ${outReject tailnetV6} 2>/dev/null \
        || note "ip6tables lan-proxy-out does not reset ${tailnetV6}"

      # 2. Control: nginx answers nobody on ${lanAddress}:443 from the LAN
      #    address, so a refusal in 3 is the rule and not a stopped nginx.
      body=$(as_nobody -sk --max-time 10 --resolve "kakapo.${zone}:443:${lanAddress}" "https://kakapo.${zone}/" || true)
      [ "$body" = kakapo ] || note "nginx did not answer https://kakapo.${zone}/ on ${lanAddress}:443, so check 3 proved nothing"

      # 3. The impersonation itself: nobody, from kakapo's tailnet address, to
      #    every gated name. Each connection must be reset (curl exit 7). Any
      #    other result means it reached nginx, where tailscale-nginx-auth
      #    would have answered "salehtl@github" (an HTTP 403 is untaggedDeny,
      #    the stopgap, catching what lan-proxy-out should have).
      v4=$(ip -4 -o addr show dev ${tsInterface} 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }' || true)
      if [ -z "$v4" ]; then
        echo "lan-proxy-spoof-check: no IPv4 address on ${tsInterface} (tailscaled down?), so no tailnet identity to pose as"
      else
        for name in ${lib.escapeShellArgs gatedNames}; do
          rc=0
          code=$(as_nobody -sk -o /dev/null -w '%{http_code}' --max-time 10 --interface "$v4" \
            --resolve "$name:443:${lanAddress}" "https://$name/") || rc=$?
          [ "$rc" = 7 ] || note "nobody reached $name from $v4 (curl exit $rc, HTTP ''${code:-none}; want exit 7): a local process can pose as kakapo's tailnet identity"
        done
      fi

      # Alert (onFailure: mail and push) on the second failing run in a row
      # only, so a firewall reload or nginx restart during one run stays quiet
      # and a lasting failure alerts once; a push on recovery.
      f="$STATE_DIRECTORY/failures"
      n=$(cat "$f" 2>/dev/null || echo 0)
      if [ "$fail" = 0 ]; then
        if [ "$n" -ge 2 ]; then
          curl -q -s --max-time 10 -o /dev/null -H "Title: [${config.networking.hostName}] lan-proxy-spoof-check recovered" \
            -d "Nothing on kakapo reaches the LAN proxy from a tailnet address again." http://127.0.0.1:2586/kakapo || true
        fi
        echo 0 >"$f"
        echo "lan-proxy-spoof-check: ok (from ''${v4:-no tailnet address}: every gated name refused)"
        exit 0
      fi
      n=$((n + 1))
      echo "$n" >"$f"
      [ "$n" -eq 2 ] && exit 1
      exit 0
    '';
  };
in
{
  # The LAN gets these names from /etc/hosts through AdGuard, which watches the
  # file. Copied, not the default symlink into /etc/static: activation then
  # replaces /etc/hosts itself, which the watcher sees. Rewrites are declared
  # empty so mutableSettings does not keep old ones.
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
    # nginx 1.30.7 fixes memory-safety advisories in HTTP/2, HTTP/3, TLS 1.3
    # and the resolver. Built from the upstream tarball until the nixos-26.05
    # channel has it; this then falls back to pkgs.nginxStable by itself.
    # Delete the override after that.
    package =
      if lib.versionOlder pkgs.nginxStable.version "1.30.7" then
        pkgs.nginxStable.overrideAttrs (_: rec {
          version = "1.30.7";
          src = pkgs.fetchurl {
            url = "https://nginx.org/download/nginx-${version}.tar.gz";
            hash = "sha256-JWW1yDcFDpWPcPsPc8SOK8pFQq00n9NW9G+wxyYQvG4=";
          };
        })
      else
        pkgs.nginxStable;
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

  # Interface-scoped, so the global allowedTCPPorts stays [ 22 ]. tailscaled's
  # ts-input chain already accepts all of tailscale0; declared anyway so the
  # firewall states the intent.
  networking.firewall.interfaces = {
    ${lanInterface}.allowedTCPPorts = [ 443 ];
    tailscale0.allowedTCPPorts = [ 443 ];
  };

  # Control 1 (header, "Identity"). Every user, root included: there is no
  # legitimate caller (the host's own requests to *.salehtl.com leave from
  # 10.0.0.215, and every health probe and Prometheus target uses 127.0.0.1).
  # A chain we flush and refill, so a reload never stacks rules.
  networking.firewall.extraCommands = ''
    iptables -w -N lan-proxy-out 2>/dev/null || true
    iptables -w -F lan-proxy-out
    iptables -w -A lan-proxy-out ${outReject tailnetV4}
    iptables -w -C OUTPUT ${outMatch} -j lan-proxy-out 2>/dev/null \
      || iptables -w -I OUTPUT ${outMatch} -j lan-proxy-out
    ip6tables -w -N lan-proxy-out 2>/dev/null || true
    ip6tables -w -F lan-proxy-out
    ip6tables -w -A lan-proxy-out ${outReject tailnetV6}
    ip6tables -w -C OUTPUT ${outMatch} -j lan-proxy-out 2>/dev/null \
      || ip6tables -w -I OUTPUT ${outMatch} -j lan-proxy-out
  '';
  networking.firewall.extraStopCommands = ''
    iptables -w -D OUTPUT ${outMatch} -j lan-proxy-out 2>/dev/null || true
    iptables -w -F lan-proxy-out 2>/dev/null || true
    iptables -w -X lan-proxy-out 2>/dev/null || true
    ip6tables -w -D OUTPUT ${outMatch} -j lan-proxy-out 2>/dev/null || true
    ip6tables -w -F lan-proxy-out 2>/dev/null || true
    ip6tables -w -X lan-proxy-out 2>/dev/null || true
  '';

  # Runs as root to read the firewall; its probes run as nobody. Alerts on the
  # second failing run in a row.
  systemd.services.lan-proxy-spoof-check = {
    description = "Check that nothing on kakapo reaches the LAN proxy from a tailnet address";
    after = [
      "firewall.service"
      "nginx.service"
      "tailscaled.service"
    ];
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe spoofCheck;
      StateDirectory = "lan-proxy-spoof-check";
      PrivateTmp = true;
      ProtectHome = true;
    };
  };
  systemd.timers.lan-proxy-spoof-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "2min";
    };
  };

  # Appended to base.nix's flags; tailscaled-set applies the whole list on
  # every start.
  services.tailscale.extraSetFlags = [ "--advertise-routes=${lanAddress}/32" ];

  # Every app is reached through this proxy, so nothing may use `tailscale
  # serve`: it would be a second route around tailscale-nginx-auth. tailscaled
  # keeps serve config in its own state, outside this flake, so clear it at
  # every boot.
  systemd.services.tailscale-serve-reset = {
    description = "Clear tailscale serve config (all ingress is the LAN proxy)";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.tailscale.package ];
    # After a cold start tailscaled answers before it has a netmap, and `serve
    # reset` fails with "netMap is nil". Retry inside the run: a Restart= loop
    # leaves the unit in auto-restart, which switch-to-configuration counts as
    # failed.
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

  # Runs on every boot and whenever the name list changes. Transient errors
  # are retried inside the run (lan-proxy-dns.sh); what is left is a real
  # problem (a hand-made record at a served name, a rotated token), mailed
  # once. No Restart= loop: a unit in auto-restart makes every activation, the
  # 04:00 upgrade included, report failure.
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
      # nothing else, and nothing may undo the untaggedDeny its server config
      # starts with. The message lists each condition.
      assertion =
        config.services.nginx.tailscaleAuth.enable
        && !(hasDirective [ "satisfy" ] httpLevelConfig)
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
          && lib.hasPrefix untaggedDeny v.extraConfig
          && !(hasDirective [ "satisfy" ] v.extraConfig)
          && !(lib.any (
            l:
            hasDirective [
              "allow"
              "deny"
              "satisfy"
            ] l.extraConfig
          ) (lib.attrValues v.locations))
        ) gatedNames;
      message = "A gated name (${lib.concatStringsSep ", " gatedNames}) is not fully behind tailscale-nginx-auth: it is missing from tailscaleAuth.virtualHosts, lacks the Expected-Tailnet check on /auth, has a location outside the gated `/` (tailscaleAuth guards only `/`), does not start its server config with the stopgap deny of kakapo and homeassistant (untaggedDeny), or has `allow`/`deny` in a location (which replaces the server's rules) or `satisfy` in the vhost or the http block (commonHttpConfig, httpConfig, appendHttpConfig). Grafana hands out admin from a header, ledger has no login and Hasala's console takes its operator's identity from the X-Webauth-User header.";
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
      # Control 2 (header, "Identity"). The message lists each condition.
      assertion =
        let
          v = config.services.nginx.virtualHosts."hasala.${zone}";
          isTailnetAddress =
            ip:
            builtins.match "100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]{1,3}\\.[0-9]{1,3}" ip != null
            || builtins.match "fd7a:115c:a1e0:[0-9a-f:]+" ip != null;
          vhostText = lib.concatStringsSep "\n" (
            [ v.extraConfig ] ++ map (l: l.extraConfig) (lib.attrValues v.locations)
          );
        in
        !(tailnetOnly ? hasala)
        || (
          consoleAllow != [ ]
          && lib.all isTailnetAddress consoleAllow
          && !(lib.any (ip: lib.elem ip serverAddresses) consoleAllow)
          && v.extraConfig == serverConfig "hasala"
          && lib.hasSuffix "deny all;\n" v.extraConfig
          && !(lib.any (
            l:
            hasDirective [
              "allow"
              "deny"
            ] l.extraConfig
          ) (lib.attrValues v.locations))
          && !(lib.hasInfix "satisfy" vhostText)
          && !(hasDirective [ "satisfy" ] httpLevelConfig)
        );
      message = "hasala.${zone} must answer only consoleDevices (modules/services/lan-proxy.nix): each entry a single tailnet address of Saleh's own Mac, iPhone or iPad, never a range, `all`, or a server node (${lib.concatStringsSep ", " (lib.attrNames servers)}), with the vhost's server config exactly the stopgap `deny`s (untaggedDeny), those `allow`s, then `deny all;`, no `allow` or `deny` in any of its locations (a location's own rules replace the server's), and no `satisfy` in the vhost or the http block (commonHttpConfig, httpConfig, appendHttpConfig). tailscale-nginx-auth vouches for every untagged node logged in as salehtl@github, servers included.";
    }
  ];
}

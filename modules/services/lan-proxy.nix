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
# Identity: the gated names (grafana and `tailnetOnly`) trust tailscale-nginx-
#          auth, which asks tailscaled who owns the connecting address. A
#          Tailscale identity is a USER, not a device: every untagged node
#          logged in as salehtl@github is "salehtl@github", and nginx-auth
#          refuses only tagged nodes. Two of those are servers: kakapo itself
#          (tailscaled's WhoIs also answers for the machine's own addresses,
#          and its ts-input chain accepts `-i lo -s <own tailnet address>`)
#          and homeassistant (runs third-party add-ons). Until 2026-10-12 any
#          local process on kakapo could therefore pose as Saleh to nginx with
#            curl --interface <kakapo's 100.x> --resolve <name>:443:10.0.0.215
#          and anything on homeassistant could over the tailnet. Three
#          controls, all in this file:
#            1. `lan-proxy-out` (firewall below) resets every locally generated
#               TCP connection to :443 on one of this host's own addresses
#               whose source is a tailnet address (100.64.0.0/10,
#               fd7a:115c:a1e0::/48), whoever owns it, root included. Tailnet
#               peers arrive on tailscale0 through INPUT and never touch it.
#               `lan-proxy-spoof-check` proves it every two minutes.
#            2. The Hasala console's vhost answers only `consoleDevices`, the
#               owner's Mac and iPhone by tailnet address, so no other
#               untagged node of his can reach it.
#            3. STOPGAP: every gated vhost denies the tailnet addresses of
#               `servers` (kakapo, homeassistant) at server level, ahead of any
#               allow (`untaggedDeny`).
#          Recommended, out-of-band and Saleh's to do: tag kakapo and
#          homeassistant in the Tailscale admin (tag:server). nginx-auth then
#          refuses them on every gated name, and control 3 is removed. See
#          CLAUDE.md first: a tagged kakapo leaves autogroup:self, which
#          Tailscale SSH rules may use.
#          KNOWN RESIDUAL RISK: these controls close the PROXY to local
#          processes, not the apps behind it. Only the console's own port is
#          closed to them, by the hasala module's `hasala-console-out` (only
#          nginx may connect to 127.0.0.1:8472). The other gated apps still
#          listen on loopback, open to every local user, as before 2026-10-12,
#          so any local user or service on kakapo can reach them there
#          directly, without nginx: Grafana on 127.0.0.1:3000 trusts a
#          Tailscale-User-Login header from loopback (admin for
#          salehtl@github), ledger on 127.0.0.1:8090 has no login, and ntfy on
#          127.0.0.1:2586 takes anonymous publishes.
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
  # Tailscale's address ranges (as in modules/services/zapret.nix).
  tailnetV4 = "100.64.0.0/10";
  tailnetV6 = "fd7a:115c:a1e0::/48";

  # The only devices the Hasala console's vhost answers: Saleh's own Mac and
  # iPhone, by their tailnet addresses (`tailscale status`; owner
  # salehtl@github, OS macOS or iOS; read 2026-10-12). A tailnet login is a
  # user, not a device, so this list is what keeps every other node logged in
  # as salehtl@github out. NEVER add kakapo, homeassistant or any other server
  # or linux node (see `servers`). A re-registered device gets a new address:
  # it then sees 403 until its address is updated here. nginx listens on IPv4
  # only, so the IPv6 entries matter only if it ever gains an IPv6 listener.
  # salehs-old-phone (iOS, offline) is left out on purpose until Saleh says it
  # is still his.
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
  # services, by their tailnet addresses (`tailscale status --json`, read
  # 2026-10-12). tailscale-nginx-auth vouches for them as Saleh, so they must
  # never be in consoleDevices (an assertion below checks), and until they are
  # tagged every gated vhost denies them (untaggedDeny).
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
  # are tagged (tag:server) in the Tailscale admin. nginx-auth refuses tagged
  # nodes on every gated name by itself, which makes it unnecessary. Until
  # then, the first lines of every gated vhost's server config, so they come
  # before any allow (consoleDevices). Server level, so they cover `/`
  # without adding a location; a location with its own allow or deny would
  # replace them, which the gated-vhost assertion refuses. kakapo's own
  # addresses are reset by lan-proxy-out before they reach nginx; denying them
  # here as well costs nothing. nginx listens on IPv4 only, so the IPv6 lines
  # matter only if it ever gains an IPv6 listener.
  untaggedDeny = lib.concatMapStrings (ip: "deny ${ip};\n") serverAddresses;

  # For the access-rule assertions. The words of an nginx config snippet,
  # split on whitespace, quotes, `;`, `{` and `}`: `allow all;` has the word
  # "allow", a header such as Access-Control-Allow-Origin does not.
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
  # has its own vhost below) or ledger; see the assertions.
  proxied = {
    # No login, by Saleh's choice (2026-10-05): anyone on the LAN or tailnet
    # can change AdGuard's filtering. Revisit if that ever matters.
    adguard = config.services.adguardhome.port;
    # Immich has its own accounts (modules/services/immich.nix).
    photos = config.services.immich.port;
    # Gramps Web has its own accounts (modules/services/grampsweb.nix).
    gw = 5000;
    # ntfy: reading needs its login; publishing is refused here (serverExtra)
    # and left to kakapo's own services on loopback (modules/services/ntfy.nix).
    # On the house network so alerts arrive while the phone's Tailscale is off.
    ntfy = 2586;
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
    # Hasala's operator console (waitlist approval, invites, mail log;
    # modules/services/hasala.nix). It has no login of its own: it trusts
    # X-Webauth-User and X-Webauth-Tailnet, which tailscale-nginx-auth sets on
    # this vhost, and admits only services.hasala.console.logins. A login is
    # a user, not a device, so the vhost also answers only consoleDevices
    # (serverExtra.hasala). The hasala module's kernel rule lets only nginx's
    # UID connect to its port. The Hasala API (8471) is public through its
    # own tunnel and must never be listed here, and the console never goes on
    # that tunnel.
    hasala = config.services.hasala.console.port;
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
    # Subscribers hold a stream open for hours. Read-only from outside:
    # anonymous visitors may publish to ntfy (kakapo's services do, on
    # 127.0.0.1:2586), so the proxy refuses every publish, including the
    # GET forms. Server-level `if ... return` only, never a location.
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
    # The console answers Saleh's own devices only (consoleDevices), on top of
    # tailscale-nginx-auth and the console's login list. Server-level, so it
    # covers `/` without adding a location (see the gated-vhost assertion);
    # everyone else gets 403 from nginx. serverConfig puts untaggedDeny ahead
    # of these allows.
    hasala = lib.concatMapStrings (ip: "allow ${ip};\n") consoleAllow + "deny all;\n";
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

  # A vhost's server-level config: on a gated name, untaggedDeny first (ahead
  # of any allow), then its serverExtra.
  serverConfig =
    name:
    lib.optionalString (lib.elem "${name}.${zone}" gatedNames) untaggedDeny
    + (serverExtra.${name} or "");

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
    extraConfig = serverConfig "grafana";
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
      proxyVhost "http://127.0.0.1:${toString port}" // { extraConfig = serverConfig name; }
    )
  ) (proxied // tailnetOnly)
  // lib.mapAttrs' (
    name: url:
    lib.nameValuePair "${name}.${zone}" (proxyVhost url // { extraConfig = serverConfig name; })
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

  # Locally generated TCP to :443 on one of this host's own addresses: the
  # packets lan-proxy-out sees. addrtype LOCAL rather than `-o lo`, because a
  # socket bound to tailscale0 routes 10.0.0.215 out of that interface
  # instead of lo. Forwarded traffic (exit-node clients) never passes OUTPUT,
  # and zapret's own packets go to remote addresses, so neither is touched.
  outMatch = "-p tcp --dport 443 -m addrtype --dst-type LOCAL";
  # lan-proxy-out's one rule, per family; the spoof check `-C`s the same text.
  # `--reject-with tcp-reset` is valid only in a rule that itself matches
  # `-p tcp` (the jump's match in OUTPUT does not count). Without it the
  # kernel refuses the rule, firewall-start stops before it attaches nixos-fw
  # to INPUT, and a reload then runs firewall-stop: on 2026-10-12 a test
  # activation left kakapo with no firewall for ~90 seconds that way.
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

  # Control 1 (header, "Identity"): nothing on kakapo may connect to the proxy
  # from a tailnet address, or tailscale-nginx-auth vouches for it as Saleh.
  # Every user, root included; there is no legitimate caller (the host's own
  # requests to *.salehtl.com leave from 10.0.0.215, and every health probe and
  # Prometheus target uses 127.0.0.1). Tailnet peers arrive on tailscale0
  # through INPUT and never pass here. A chain we flush and refill, like
  # hasala-console-out, so a reload never stacks rules.
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

  # Proves control 1 every two minutes (it runs as root to read the firewall;
  # its probes run as nobody). Mails and pushes through notify-failure on the
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
      # tailnet check on /auth. Its server config starts with untaggedDeny
      # (control 3), and nothing may undo that: no allow or deny in a location
      # (nginx then uses the location's rules and drops the server's), and no
      # `satisfy` in the vhost or the http block.
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
      # Control 2 (header, "Identity"). Each entry is one tailnet address,
      # never a range or `all`, never a server's; and the console's vhost has
      # exactly untaggedDeny, those allows, then `deny all;` at server level.
      # Nothing may undo that: no allow or deny in any of its locations (nginx
      # then uses the location's rules and drops the server's), and no
      # `satisfy any`, in the vhost or the http block, that would let
      # tailscale-nginx-auth alone admit a caller.
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
    {
      assertion = !(lib.elem ledgerPort (lib.attrValues proxied));
      message = "ledger is in `proxied`, which forwards without authentication. It has no login, holds financial data and is tailnet-only by policy (modules/services/ledger.nix); keep it in `tailnetOnly`.";
    }
  ];
}

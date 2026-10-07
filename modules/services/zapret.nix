# zapret (nfqws): DPI bypass for traffic leaving through kakapo as a Tailscale
# exit node. The ISP resets TLS handshakes whose SNI names a blocked site (not
# the IP: a blocked SNI sent to an allowed server is reset too, and the blocked
# server's IP answers under another name). nfqws re-segments the first packets
# of each HTTPS connection so the SNI is split across TCP segments, which this
# DPI does not reassemble. No fakes, no TTL tricks: the server receives exactly
# the bytes the client sent.
#
# Strategy from `blockcheck` on this line (2026-10-07, see the commit message).
# If the ISP changes its DPI and blocked sites start resetting again, rerun it:
#
#   sudo env BATCH=1 DOMAINS=<blocked domain> IPVS=4 ENABLE_HTTP=0 \
#     ENABLE_HTTP3=0 SKIP_TPWS=1 FWTYPE=iptables \
#     nix shell nixpkgs#zapret nixpkgs#iptables nixpkgs#curl -c blockcheck
#
# Scope: only forwarded traffic from tailnet clients (source 100.64.0.0/10,
# matched in mangle POSTROUTING, which runs before Tailscale's masquerade).
# kakapo's own traffic, including the 04:00 nixos-upgrade, never enters the
# queue. LAN devices are unaffected: kakapo is not their gateway; they get
# this only by selecting kakapo as their exit node.
#
# Failure mode: `--queue-bypass` passes packets through untouched when nfqws
# is not running, so a crashed nfqws degrades to "no bypass", never to "no
# internet" for exit-node clients.
#
# Not services.zapret.configureFirewall: that inserts its POSTROUTING rules
# with -I on every firewall reload and never removes them, so they pile up.
# Our rules live in a chain we flush and re-fill instead.
#
# Out-of-band: the exit node must be approved in the Tailscale admin console
# (Machines -> kakapo -> Edit route settings -> Use as exit node).
{ config, ... }:
let
  qnum = toString config.services.zapret.qnum;
  tailnetV4 = "100.64.0.0/10";
  tailnetV6 = "fd7a:115c:a1e0::/48";
  # Only the first packets carry the ClientHello; skip the rest of the flow.
  firstPackets = "-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:6";
  # nfqws marks the packets it sends itself with this bit; never requeue them.
  notOwn = "-m mark ! --mark 0x40000000/0x40000000";
  queue = "-j NFQUEUE --queue-num ${qnum} --queue-bypass";
in
{
  services.tailscale = {
    # IPv4 + IPv6 forwarding. The LAN has no global IPv6, so forwarding v6
    # (which stops the kernel accepting RAs) costs kakapo no address.
    useRoutingFeatures = "server";
    extraSetFlags = [ "--advertise-exit-node" ];
  };

  services.zapret = {
    enable = true;
    configureFirewall = false;
    params = [
      "--dpi-desync=multisplit"
      "--dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1"
    ];
  };

  networking.firewall.extraCommands = ''
    iptables -t mangle -N kakapo-zapret 2>/dev/null || true
    iptables -t mangle -F kakapo-zapret
    iptables -t mangle -A kakapo-zapret -s ${tailnetV4} -p tcp --dport 443 ${firstPackets} ${notOwn} ${queue}
    iptables -t mangle -C POSTROUTING -j kakapo-zapret 2>/dev/null || iptables -t mangle -A POSTROUTING -j kakapo-zapret

    ip6tables -t mangle -N kakapo-zapret 2>/dev/null || true
    ip6tables -t mangle -F kakapo-zapret
    ip6tables -t mangle -A kakapo-zapret -s ${tailnetV6} -p tcp --dport 443 ${firstPackets} ${notOwn} ${queue}
    ip6tables -t mangle -C POSTROUTING -j kakapo-zapret 2>/dev/null || ip6tables -t mangle -A POSTROUTING -j kakapo-zapret
  '';

  networking.firewall.extraStopCommands = ''
    iptables -t mangle -D POSTROUTING -j kakapo-zapret 2>/dev/null || true
    ip6tables -t mangle -D POSTROUTING -j kakapo-zapret 2>/dev/null || true
  '';
}

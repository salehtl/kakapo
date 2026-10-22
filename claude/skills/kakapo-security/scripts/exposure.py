#!/usr/bin/env python3
"""Classify kakapo's listening sockets against the documented port invariants.

Usage (read-only; only `ss` needs root, to see process names):
    sudo ss -H -tulpn | python3 -I exposure.py

Invariants (CLAUDE.md, "Conventions worth preserving"):
  - 22/tcp (sshd) on every interface
  - 53/tcp+udp (AdGuardHome) bound wildcard, firewall-scoped to LAN NIC + tailscale0
  - 443/tcp (nginx) on the LAN address 10.0.0.215 only
  - everything else on loopback
Known non-loopback sockets that are not services: tailscaled's WireGuard
port and peerapi, and cloudflared's outbound QUIC sockets (UNCONN udp on
ephemeral ports; they show up in `ss -u` but accept nothing unsolicited).

Prints one line per socket: VERDICT proto local process. Exit 1 if any
socket is UNEXPECTED, else 0.
"""
import ipaddress
import re
import sys

LAN_ADDRESS = "10.0.0.215"  # lanAddress in modules/services/lan-proxy.nix
TAILNET_V4 = ipaddress.ip_network("100.64.0.0/10")
TAILNET_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")


def split_addr(local):
    host, _, port = local.rpartition(":")
    host = host.strip("[]").split("%")[0]
    return host, int(port) if port.isdigit() else -1


def is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def in_tailnet(host):
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip in (TAILNET_V4 if ip.version == 4 else TAILNET_V6)


def classify(proto, host, port, proc):
    wildcard = host in ("*", "0.0.0.0", "::")
    if is_loopback(host):
        return "LOOPBACK", ""
    if proto == "tcp" and port == 22 and "sshd" in proc and wildcard:
        return "EXPECTED", "sshd, every interface by design"
    if port == 53 and "AdGuardHome" in proc and wildcard:
        return "EXPECTED", "AdGuard DNS; firewall scopes it to LAN NIC + tailscale0"
    if proto == "tcp" and port == 443 and "nginx" in proc and host == LAN_ADDRESS:
        return "EXPECTED", "LAN proxy"
    if "tailscaled" in proc and (in_tailnet(host) or (proto == "udp" and port == 41641)):
        return "EXPECTED", "tailscaled (WireGuard / peerapi)"
    if proto == "udp" and "cloudflared" in proc and wildcard:
        return "EXPECTED", "cloudflared outbound QUIC (Hasala tunnel)"
    return "UNEXPECTED", "not loopback and not a documented exception"


def main():
    bad = 0
    rows = []
    for line in sys.stdin:
        cols = line.split()
        if len(cols) < 5:
            continue
        proto, local = cols[0], cols[4]
        proc = " ".join(cols[6:]) if len(cols) > 6 else "?"
        names = ",".join(sorted(set(re.findall(r'\(\("?([^",]+)', proc) or re.findall(r'"([^"]+)"', proc)))) or proc
        host, port = split_addr(local)
        verdict, why = classify(proto, host, port, names)
        bad += verdict == "UNEXPECTED"
        rows.append((verdict, proto, local, names, why))
    order = {"UNEXPECTED": 0, "EXPECTED": 1, "LOOPBACK": 2}
    for v, proto, local, names, why in sorted(set(rows), key=lambda r: (order[r[0]], r[2])):
        print(f"{v:<10} {proto:<4} {local:<40} {names:<24} {why}")
    if not rows:
        print("no input: pipe `sudo ss -H -tulpn` into this script", file=sys.stderr)
        return 2
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

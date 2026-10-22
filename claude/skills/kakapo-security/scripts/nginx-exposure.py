#!/usr/bin/env python3
"""Tabulate the nginx vhosts kakapo is actually serving, and their gate.

Usage (no root needed; the config is in the world-readable store):
    python3 -I nginx-exposure.py [--gated name,name] [nginx.conf]

With no config argument it reads the running master's command line, which
names the config it started with. NixOS restarts nginx when that file
changes, so a mismatch with /run/current-system's nginx.service means a
failed restart. Pass a built config (for example master's) to audit that.

nginx gates per location, so each `location` is graded on its own: it is
gated when it has `auth_request <uri>;`, or the server has one and the
location does not say `auth_request off;`. `internal` locations (the /auth
subrequest) are skipped. A vhost is GATED (all locations gated), PARTIAL
(some), OPEN (none), STATIC (no proxy_pass at all, e.g. the kakapo test
page) or REJECT (`ssl_reject_handshake on`, the default server).

Violations (exit 1):
  - a MUST_BE_GATED name (plus --gated names) that is not GATED;
  - any PARTIAL vhost (an ungated sibling location bypasses the gate);
  - an ungated location anywhere that proxies to a gated app's port;
  - a `listen` that is not 10.0.0.215:443.
"""
import re
import subprocess
import sys

# grafana has its own vhost; ledger and hasala are in `tailnetOnly`. Grafana
# grants admin from a header, ledger has no login, the Hasala console trusts
# X-Webauth-User. Add any other `tailnetOnly` key with --gated.
MUST_BE_GATED = {"grafana", "ledger", "hasala"}
LISTEN = "10.0.0.215:443"


def blocks(text, keyword):
    """Yield (head, body, start, end) of `keyword ... {...}` blocks in text."""
    for m in re.finditer(r"\b%s\b[^{;]*\{" % keyword, text):
        depth, i = 1, m.end()
        while depth and i < len(text):
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        yield m.group(0), text[m.end(): i - 1], m.start(), i


def port(upstream):
    m = re.search(r":(\d+)(/|$)", upstream or "")
    return m.group(1) if m else upstream


def auth_on(text):
    return any(v.strip() != "off" for v in re.findall(r"\bauth_request\s+([^;]+);", text))


def running_conf():
    pid = subprocess.run(["systemctl", "show", "-p", "MainPID", "--value", "nginx"],
                         capture_output=True, text=True).stdout.strip()
    cmd = open(f"/proc/{pid}/cmdline").read().replace("\0", " ")
    m = re.search(r"(/nix/store/\S+-nginx\.conf)", cmd)
    if not m:
        sys.exit(f"cannot find nginx.conf in the master's command line: {cmd!r}")
    unit = open("/run/current-system/etc/systemd/system/nginx.service").read()
    if m.group(1) not in unit:
        print(f"WARNING: running nginx uses {m.group(1)}, not the config in "
              "/run/current-system's nginx.service (failed restart?)")
    return m.group(1)


def main():
    args = sys.argv[1:]
    must = set(MUST_BE_GATED)
    if "--gated" in args:
        i = args.index("--gated")
        must |= {x.strip() for x in args[i + 1].split(",") if x.strip()}
        del args[i:i + 2]
    conf = args[0] if args else running_conf()
    print(f"config: {conf}")
    text = re.sub(r"#[^\n]*", "", open(conf).read())

    vhosts = []
    for _, body, _, _ in blocks(text, "server"):
        names = re.findall(r"server_name\s+([^;]+);", body)
        name = names[0].strip() if names else "?"
        listens = [x.strip() for x in re.findall(r"\blisten\s+([^;]+);", body)]
        locs = list(blocks(body, "location"))
        server_level = body
        for _, _, s, e in reversed(locs):
            server_level = server_level[:s] + server_level[e:]
        srv_auth = auth_on(server_level)
        rows = []  # (path, proxy_pass or None, gated)
        for head, loc, _, _ in locs:
            if re.search(r"\binternal\s*;", loc):
                continue
            path = re.sub(r"^location\s+|\s*\{$", "", head).strip()
            p = re.search(r"proxy_pass\s+([^;]+);", loc)
            off = re.search(r"\bauth_request\s+off\s*;", loc)
            gated = auth_on(loc) or (srv_auth and not off)
            rows.append((path, p.group(1).strip() if p else None, gated))
        if re.search(r"\bssl_reject_handshake\s+on\s*;", body):
            gate = "REJECT"
        elif not any(r[1] for r in rows):
            gate = "STATIC"
        elif all(r[2] for r in rows):
            gate = "GATED"
        elif any(r[2] for r in rows):
            gate = "PARTIAL"
        else:
            gate = "OPEN"
        rules = " ".join(f"{a} {b};" for a, b in re.findall(r"\b(allow|deny)\s+([^;]+);", body))
        vhosts.append((name, listens, rows, gate, rules))

    bad = []
    gated_upstreams = {}
    for name, _, rows, gate, _ in vhosts:
        if name.split(".")[0] in must:
            for _, up, _ in rows:
                if up:
                    gated_upstreams[port(up)] = name

    print(f"{'server_name':<26} {'gate':<8} {'upstream (/)':<30} listen / access rules")
    for name, listens, rows, gate, rules in vhosts:
        up = next((u for p, u, _ in rows if p == "/"), None) or "-"
        print(f"{name:<26} {gate:<8} {up:<30} {','.join(listens)}  {rules}")
        for path, u, g in rows:
            if not g and gate in ("PARTIAL", "GATED"):
                print(f"{'':<26} ungated location {path} -> {u}")
        short = name.split(".")[0]
        if short in must and gate != "GATED":
            bad.append(f"{name} is {gate} but must be GATED behind tailscale-nginx-auth")
        elif gate == "PARTIAL":
            bad.append(f"{name} is PARTIAL: an ungated location bypasses the gate")
        for path, u, g in rows:
            if u and not g and port(u) in gated_upstreams and short not in must:
                bad.append(f"{name} location {path} proxies ungated to {u}, the port of "
                           f"{gated_upstreams[port(u)]}")
        for listen in listens:
            if not listen.startswith(LISTEN):
                bad.append(f"{name} listens on {listen}, not only {LISTEN}")
    for b in bad:
        print("VIOLATION:", b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

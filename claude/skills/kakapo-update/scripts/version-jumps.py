#!/usr/bin/env python3
"""Sort a closure diff into what needs reading and what does not.

    python3 -I version-jumps.py /run/current-system "$out"

Runs `nix store diff-closures <old> <new>`, strips its colour codes, and
prints three sections:

  WATCHED  packages that are services or state owners on kakapo, every
           version change (any change to these deserves a changelog look)
  MAJOR    any other package whose major version changed (for 0.x, the minor)
  OTHER    a count of the remaining version changes, and the package list
           with --all

Also says whether the new kernel or initrd differs from the booted system
(/run/booted-system) and from <old>: a reboot is needed when it differs from
the booted one, because activation alone does not load a kernel.
Standard library only.
"""
import os
import re
import subprocess
import sys

# Services and state owners on kakapo. Keep in step with modules/services/
# and hosts/kakapo/. A name matches when the diff-closures package name
# equals it or starts with it followed by "-". Listed in print order: data
# owners and reboot-relevant packages first.
WATCHED = [
    "immich", "postgresql", "vectorchord", "pgvector", "linux",
    "nvidia-open", "nvidia-x11", "nvidia-persistenced", "adguardhome",
    "nginx", "ntfy-sh", "grafana", "prometheus", "redis", "valkey",
    "systemd", "openssh", "tailscale", "iptables", "glibc", "openssl",
    "docker", "containerd", "runc", "zapret", "cloudflared",
    "sops-install-secrets", "nix", "nss-cacert", "msmtp", "ledger",
    "hasala", "claude-code",
]
# Matched by exact name only: their prefixes catch unrelated packages
# (linux-pam, linux-headers, nix-direnv). nix-* sub-packages that move with
# nix are folded into its row.
EXACT = {"linux", "nix"}
EMPTY = ("", "∅", "ε")  # nothing, or a versionless store path

ANSI = re.compile(r"\x1b\[[0-9;]*m")
SIZE = re.compile(r",\s*[+-]?[0-9.]+ [KMGT]?i?B$")
LINE = re.compile(r"^(?P<name>[^:]+): (?P<rest>.*)$")


def rank(name):
    """Index in WATCHED, or None when the package is not watched."""
    for i, w in enumerate(WATCHED):
        if name == w or (w not in EXACT and name.startswith(w + "-")):
            return i
    return None


def major(v):
    parts = re.split(r"[.\-+]", v)
    if not parts or not parts[0].isdigit():
        return None
    if parts[0] == "0" and len(parts) > 1:
        return "0." + parts[1]
    return parts[0]


def main(old, new, show_all):
    diff = subprocess.run(
        ["nix", "store", "diff-closures", old, new],
        capture_output=True, text=True, check=True,
    ).stdout
    rows = []
    for raw in diff.splitlines():
        m = LINE.match(ANSI.sub("", raw).strip())
        if not m:
            continue
        rest = m["rest"]
        if "→" not in rest:
            continue  # size-only change
        # "<old versions> → <new versions>[, <size delta>]"; several
        # versions on one side are joined with ", ".
        rest = SIZE.sub("", rest)
        rows.append((m["name"], rest.strip()))

    w, maj, other = [], [], []
    nix_versions = dict(rows).get("nix")
    folded = 0
    for name, versions in rows:
        if name.startswith("nix-") and versions == nix_versions:
            folded += 1
            continue
        olds, news = (s.strip() for s in versions.split("→"))
        o_maj = {major(v.strip()) for v in olds.split(",") if v.strip() not in EMPTY}
        n_maj = {major(v.strip()) for v in news.split(",") if v.strip() not in EMPTY}
        o_maj.discard(None)
        n_maj.discard(None)
        jump = bool(o_maj and n_maj and o_maj != n_maj)
        tag = " [MAJOR]" if jump else ""
        r = rank(name)
        if r is not None and re.search(r"[0-9]", versions):
            w.append((r, f"  {name}: {versions}{tag}"))
        elif jump:
            maj.append(f"  {name}: {versions}")
        else:
            other.append(f"  {name}: {versions}")
    w = [line for _, line in sorted(w)]
    if folded:
        w = [l + f" (+{folded} nix-* sub-packages)" if l.startswith("  nix: ") else l for l in w]

    print("WATCHED")
    print("\n".join(w) if w else "  (none changed)")
    print("MAJOR (not watched)")
    print("\n".join(maj) if maj else "  (none)")
    print(f"OTHER: {len(other)} version changes")
    if show_all and other:
        print("\n".join(other))

    booted = "/run/booted-system"
    for part in ("kernel", "initrd"):
        b = os.path.realpath(os.path.join(new, part))
        vs_old = "differs from" if os.path.realpath(os.path.join(old, part)) != b else "same as"
        line = f"{part}: {vs_old} {old}"
        if os.path.exists(booted):
            if os.path.realpath(os.path.join(booted, part)) != b:
                line += "; differs from the booted system (reboot needed to run it)"
            else:
                line += "; same as the booted system (no reboot needed)"
        print(line)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--all"]
    if len(args) != 2:
        sys.exit("usage: version-jumps.py [--all] <old system> <new system>")
    main(args[0], args[1], "--all" in sys.argv[1:])

#!/usr/bin/env python3
"""Show the age of each root input pinned in flake.lock.

Usage: python3 -I lock-age.py <repo>/flake.lock [days-threshold, default 21]

Only the root inputs matter (nested nodes such as `nixpkgs` under ledger are
not what the host is built from). 21 days matches the `nixpkgs-age` alert in
modules/notify.nix. Exit 1 if a package-set input is older than the
threshold: `nixpkgs` (the host) or `nixpkgs-unstable` (Immich, exposed on
photos.salehtl.com).
"""
import datetime
import json
import sys


PACKAGE_SETS = {"nixpkgs", "nixpkgs-unstable"}


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 21
    lock = json.load(open(sys.argv[1]))
    nodes = lock["nodes"]
    now = datetime.datetime.now(datetime.timezone.utc)
    stale = False
    for name, ref in sorted(nodes[lock["root"]]["inputs"].items()):
        node = ref if isinstance(ref, str) else ref[-1]
        locked = nodes[node].get("locked", {})
        ts = locked.get("lastModified")
        if ts is None:
            print(f"{name:<18} (no lastModified)")
            continue
        when = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
        age = (now - when).days
        flag = ""
        if name in PACKAGE_SETS and age > limit:
            flag, stale = f"  STALE (> {limit} d): unpatched CVEs likely", True
        print(f"{name:<18} {locked.get('rev', '')[:12]:<13} {when:%Y-%m-%d} {age:>4} d{flag}")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())

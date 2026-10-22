#!/usr/bin/env python3
"""Show what moved between two flake.lock files.

    git show origin/master:flake.lock > /tmp/base.lock     # or any path
    python3 -I lock-diff.py /tmp/base.lock flake.lock

For each input reachable from the root (named by its path, e.g. `nixpkgs`,
`hasala/nixpkgs`), prints old -> new revision, the commit dates, the age gap
in days, and a GitHub compare URL. Lock node names (`nixpkgs_2`, ...) are not
stable between locks, so inputs are matched by path, not by node name.

Prints `SOURCE CHANGED:` and exits 1 when an input's source (type, owner,
repo, url, host or ref, in `locked` or `original`) differs: for example
nixpkgs pointed at a fork. A routine bump only moves revs.
Standard library only: kakapo has python3 but not jq.
"""
import datetime
import json
import sys


def walk(lock):
    """Map input path -> locked attrs, following `follows` lists."""
    nodes = lock["nodes"]
    out = {}

    def resolve(ref):
        # A string is a node name; a list is a `follows` path from the root.
        if isinstance(ref, str):
            return ref
        node = lock["root"]
        for part in ref:
            node = resolve(nodes[node]["inputs"][part])
        return node

    def visit(name, prefix, seen):
        for inp, ref in nodes[name].get("inputs", {}).items():
            path = f"{prefix}{inp}"
            child = resolve(ref)
            if isinstance(ref, list):
                out[path] = {"follows": "/".join(ref)}
                continue
            out[path] = dict(nodes[child].get("locked", {}))
            out[path]["_original"] = nodes[child].get("original", {})
            if child not in seen:
                visit(child, path + "/", seen | {child})

    visit(lock["root"], "", {lock["root"]})
    return out


SOURCE_KEYS = ("type", "owner", "repo", "url", "host", "ref")


def source(attrs):
    """The parts of an input that say where it comes from, not which rev."""
    pick = lambda d: tuple(f"{k}={d[k]}" for k in SOURCE_KEYS if k in d)
    return pick(attrs) + tuple("original." + x for x in pick(attrs.get("_original", {})))


def date(locked):
    ts = locked.get("lastModified")
    if not ts:
        return "?"
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")


def main(old_path, new_path):
    old = walk(json.load(open(old_path)))
    new = walk(json.load(open(new_path)))
    moved = 0
    source_changed = False
    for path in sorted(set(old) | set(new)):
        a, b = old.get(path), new.get(path)
        if a == b:
            continue
        moved += 1
        if a is None or b is None:
            print(f"{path}: {'added' if a is None else 'removed'}")
            continue
        if "follows" in a or "follows" in b:
            print(f"{path}: follows {a.get('follows', '-')} -> {b.get('follows', '-')}")
            continue
        if source(a) != source(b):
            source_changed = True
            print(f"SOURCE CHANGED: {path}: {' '.join(source(a))} -> {' '.join(source(b))}")
        ra, rb = a.get("rev", "?"), b.get("rev", "?")
        gap = ""
        if a.get("lastModified") and b.get("lastModified"):
            gap = f", {(b['lastModified'] - a['lastModified']) // 86400:+d} days"
        print(f"{path}: {ra[:12]} ({date(a)}) -> {rb[:12]} ({date(b)}){gap}")
        if b.get("type") == "github" and source(a) == source(b):
            print(f"    https://github.com/{b['owner']}/{b['repo']}/compare/{ra}...{rb}")
    if not moved:
        print("no input moved")
    if source_changed:
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: lock-diff.py <old flake.lock> <new flake.lock>")
    main(sys.argv[1], sys.argv[2])

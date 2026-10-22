#!/usr/bin/env python3
"""Check that every file under secrets/ is sops-encrypted, now and in history.

Usage: python3 -I check-sops.py <repo>

Checks, for the working tree and for every version of every file that ever
existed under secrets/ in any branch:
  - the file is *.yaml (the only kind .sops.yaml's creation rule covers)
  - it has a top-level `sops:` block with a `mac: ENC[...]`
  - every value outside that block is ENC[...] (or its key ends in
    `_unencrypted`, sops' own opt-out suffix, which is itself a finding)
  - in the working tree, every age recipient in .sops.yaml is present
Never prints a value: a plaintext hit is reported by file, commit and key.
Exit 1 on any finding.
"""
import re
import subprocess
import sys

LEAF = re.compile(r"^(\s*)(-\s+)?([^\s:#][^:]*):\s*(.*)$")


def problems(text, recipients=()):
    out = []
    lines = text.splitlines()
    if not any(l.startswith("sops:") for l in lines):
        return ["no top-level `sops:` block (not a sops file, likely plaintext)"]
    if not re.search(r"^\s+mac:\s*ENC\[", text, re.M):
        out.append("sops block has no encrypted `mac`")
    in_sops = False
    for n, line in enumerate(lines, 1):
        if line.startswith("sops:"):
            in_sops = True
            continue
        if in_sops and line and not line[0].isspace():
            in_sops = False
        if in_sops or not line.strip() or line.lstrip().startswith("#"):
            continue
        m = LEAF.match(line)
        if not m:
            if not line.strip().startswith("ENC["):
                out.append(f"line {n}: unparsed line (possible plaintext block)")
            continue
        key, value = m.group(3), m.group(4).strip()
        if key.endswith("_unencrypted"):
            out.append(f"line {n}: key `{key}` is deliberately unencrypted")
        elif value in ("", "|", ">", "|-", ">-"):
            if value:  # block scalar: the next lines are plaintext
                out.append(f"line {n}: key `{key}` holds a plaintext block scalar")
        elif not value.startswith("ENC["):
            out.append(f"line {n}: key `{key}` is not ENC[...]")
    for r in recipients:
        if r not in text:
            out.append(f"age recipient {r[:16]}... from .sops.yaml is missing")
    return out


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True,
                          capture_output=True, text=True).stdout


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    repo = sys.argv[1]
    recipients = re.findall(r"\bage1[0-9a-z]{58}\b", open(f"{repo}/.sops.yaml").read())
    found = 0

    for path in git(repo, "ls-files", "secrets/").split():
        msgs = [] if path.endswith(".yaml") else ["not *.yaml: .sops.yaml does not cover it"]
        msgs += problems(open(f"{repo}/{path}").read(), recipients)
        for m in msgs:
            print(f"WORKTREE {path}: {m}")
            found += 1

    seen = set()
    for commit in git(repo, "log", "--all", "--format=%H", "--", "secrets/").split():
        for entry in git(repo, "ls-tree", "-r", commit, "--", "secrets/").splitlines():
            meta, path = entry.split("\t", 1)
            blob = meta.split()[2]
            if blob in seen:
                continue
            seen.add(blob)
            msgs = [] if path.endswith(".yaml") else ["not *.yaml"]
            msgs += problems(git(repo, "cat-file", "-p", blob))
            for m in msgs:
                print(f"HISTORY {commit[:10]} {path}: {m}")
                found += 1

    print(f"checked {len(seen)} historical blobs; {found} finding(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())

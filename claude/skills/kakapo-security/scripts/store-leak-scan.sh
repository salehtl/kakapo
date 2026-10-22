#!/usr/bin/env bash
# Look for any deployed secret value inside the world-readable /nix/store.
#
# Usage: sudo bash /etc/claude-code/skills/kakapo-security/scripts/store-leak-scan.sh [store-path...]
#
# Default targets: /run/current-system, /run/booted-system and every
# /nix/var/nix/profiles/system-*-link (a leak "fixed" in a later commit stays
# on disk until those generations are deleted and the store is collected),
# plus the .drv files of the current system (a value inlined at eval time is
# in the derivation even when no output contains it).
#
# /nix/store is world-readable, so a secret that reaches it (a value inlined
# into a unit, an env file built by pkgs.writeText, a builtins.readFile of a
# decrypted file) is readable by every local user and service. This reads
# each decrypted file under /run/secrets (root only), turns it into search
# strings, and greps the targets for them.
#
# Search strings per secret file: each line, the value after NAME= (env
# files), and the values of "key":"value" (JSON, except keys ending in ID or
# Tag: cloudflared's TunnelID and AccountTag are identifiers that the tunnel
# config must name) and key: value (YAML). One is
# kept when it looks like a secret: at least 16 characters, no whitespace, no
# "://", no "@", not PEM armour (-----BEGIN ...), and letters plus a digit or
# one of - _ + / = (so an app password like xxxx-xxxx-xxxx-xxxx counts).
# Secrets with no search string are printed as NOT SCANNED.
#
# It never prints a secret value: only the store file that matched and the
# /run/secrets name whose value it contains. The pattern files live in a
# 0700 root directory on tmpfs and are removed on exit. Read-only otherwise.
# About a minute on kakapo.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }

work=$(mktemp -d /run/kakapo-leakscan.XXXXXX)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
mkdir "$work/by-secret"

strings_of() {
  awk '{
    gsub(/^[ \t]+|[ \t\r]+$/, "")
    n = 1; c[1] = $0
    v = $0
    if (sub(/^[A-Za-z_][A-Za-z0-9_]*=/, "", v)) { gsub(/^["\047]|["\047]$/, "", v); c[++n] = v }
    v = $0
    if (sub(/^[A-Za-z_][A-Za-z0-9_.-]*:[ \t]+/, "", v)) { gsub(/^["\047]|["\047]$/, "", v); c[++n] = v }
    rest = $0
    while (match(rest, /"[^"\\]*"[ \t]*:[ \t]*"[^"\\]*"/)) {
      kv = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
      k = kv; sub(/"[ \t]*:.*/, "", k)
      sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", kv); sub(/"$/, "", kv)
      if (tolower(k) !~ /(id|tag)$/) c[++n] = kv   # identifiers (TunnelID, AccountTag) are public
    }
    for (i = 1; i <= n; i++) {
      s = c[i]
      if (length(s) < 16 || s ~ /[ \t]/ || s ~ /^-----/ || s ~ /:\/\// || s ~ /@/) continue
      if (s !~ /[A-Za-z]/ || s !~ /[0-9_+\/=-]/) continue
      print s
    }
  }' "$1" | sort -u
}

count=0
while IFS= read -r -d '' f; do
  name=${f#/run/secrets/}
  out="$work/by-secret/$(printf '%s' "$name" | tr '/' '%')"
  strings_of "$f" >"$out"
  n=$(wc -l <"$out")
  if [ "$n" -eq 0 ]; then echo "NOT SCANNED: $name (no secret-looking value)"; else echo "secret: $name ($n search strings)"; fi
  count=$((count + 1))
done < <(find -L /run/secrets -type f -print0 | sort -z)
cat "$work"/by-secret/* | sort -u >"$work/patterns"
echo "search strings: $(wc -l <"$work/patterns") from $count secret files"
[ -s "$work/patterns" ] || { echo "RESULT: nothing to search for (no secret-looking values)"; exit 0; }

if [ $# -gt 0 ]; then
  targets=("$@")
else
  targets=(/run/current-system /run/booted-system /nix/var/nix/profiles/system-*-link)
fi
for t in "${targets[@]}"; do nix-store -qR "$t"; done >"$work/paths"
drvs=0
if [ $# -eq 0 ] && drv=$(nix-store -qd /run/current-system 2>/dev/null) && [ -e "$drv" ]; then
  nix-store -qR "$drv" | grep '\.drv$' >>"$work/paths"
  drvs=1
fi
sort -u -o "$work/paths" "$work/paths"
echo "scanned: ${#targets[@]} system closures (${targets[0]} ... ${targets[-1]})$([ "$drvs" = 1 ] && echo ' + .drv files of /run/current-system'); $(wc -l <"$work/paths") store paths"

xargs -a "$work/paths" -d '\n' grep -rlF -f "$work/patterns" -- 2>/dev/null >"$work/hits" || true

if [ ! -s "$work/hits" ]; then
  echo "RESULT: no secret value found in the scanned store paths"
  exit 0
fi
echo "RESULT: secret values found in the world-readable store:"
while IFS= read -r hit; do
  for p in "$work"/by-secret/*; do
    [ -s "$p" ] || continue
    if grep -qF -f "$p" -- "$hit"; then
      echo "  $hit  contains a value of  $(basename "$p" | tr '%' '/')"
    fi
  done
done <"$work/hits"
exit 1

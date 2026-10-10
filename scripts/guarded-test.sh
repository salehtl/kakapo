#!/usr/bin/env bash
# Activate a built system with `switch-to-configuration test`, then watch the
# house's DNS for ~40s and roll back to the running system if AdGuard stops
# answering (3 failed probes in a row), or if the activation itself failed.
# Use it for any change that can touch AdGuard or networking -- the whole
# house resolves through kakapo.
#
#   out=$(nix build --no-link --print-out-paths .#nixosConfigurations.kakapo.config.system.build.toplevel)
#   scripts/guarded-test.sh "$out"
set -u
new=$(readlink -f "${1:?usage: guarded-test.sh <system store path>}")

# One activation at a time. Several agents can work on kakapo at once, each
# testing its own branch on the one live host; without this, a second test
# activates mid-way through the first's watch window and the first reports a
# clean test of a system that was replaced under it. Every test goes through
# this script, so the lock serializes them all. A lock on a read-only fd is
# enough for flock, so a file created by another user still works.
lock=/tmp/kakapo-guarded-test.lock
[ -e "$lock" ] || (umask 022 && : >"$lock")
exec 9<"$lock"
if ! flock -n 9; then
  echo "another guarded-test.sh is running; waiting for it (up to 15 min)" >&2
  flock -w 900 9 || { echo "gave up waiting for the guarded-test lock" >&2; exit 5; }
fi

prev=$(readlink /run/current-system)
dig=$(nix build --no-link --print-out-paths 'nixpkgs#dnsutils^dnsutils')/bin/dig
lan=enp4s0 # the LAN NIC (modules/services/adguard.nix, lan-proxy.nix)
# The query runs over `lo`: kakapo asking its own address never touches the
# LAN NIC or its interface-scoped firewall rules, so check those too. The
# house reaches :53 and :443 only through them.
probe() {
  "$dig" +short +time=2 +tries=1 @10.0.0.215 one.one.one.one A | grep -q '^[0-9]' &&
    ip -4 -o addr show dev "$lan" | grep -q ' 10\.0\.0\.215/' &&
    sudo iptables -C nixos-fw -i "$lan" -p udp --dport 53 -j nixos-fw-accept 2>/dev/null &&
    sudo iptables -C nixos-fw -i "$lan" -p tcp --dport 443 -j nixos-fw-accept 2>/dev/null
}
# What switch-to-configuration counts as failed.
failed_units() { systemctl list-units --state=failed,auto-restart --plain --no-legend | cut -d' ' -f1 | sort; }

probe || { echo "DNS or the LAN path already failing before activation; not activating" >&2; exit 2; }
failed_before=$(failed_units)
sudo "$new/bin/switch-to-configuration" test
rc=$?
echo "activation exit $rc"
fails=0
for i in $(seq 1 20); do
  if probe; then fails=0; else
    fails=$((fails + 1))
    echo "probe $i failed ($fails in a row)"
  fi
  if [ "$fails" -ge 3 ]; then
    echo "DNS DOWN -> rolling back to $prev" >&2
    sudo "$prev/bin/switch-to-configuration" test >/dev/null 2>&1
    if probe; then echo "rolled back; DNS answering" >&2; else echo "ROLLBACK DID NOT RESTORE DNS: systemctl restart adguardhome" >&2; fi
    exit 1
  fi
  sleep 2
done
echo "DNS answered throughout"

# Something else can switch the system underneath a test: on 2026-10-06/07
# nixos-upgrade.timer fired mid-activation and switched to master. Say so
# rather than report a clean test of a system that is no longer running.
if [ "$(readlink /run/current-system)" != "$new" ]; then
  echo "WARNING: $new is no longer the running system (now $(readlink /run/current-system)); check nixos-upgrade.service" >&2
  exit 3
fi

# A failed activation can leave the host broken while DNS still answers (a
# firewall that failed to load leaves INPUT open). Exit 4 means units failed;
# only those that were not already failed before count against this test.
new_failed=$(comm -13 <(printf '%s\n' "$failed_before") <(failed_units) | xargs)
if [ "$rc" -ne 0 ] && { [ "$rc" -ne 4 ] || [ -n "$new_failed" ]; }; then
  echo "ACTIVATION FAILED (exit $rc; newly failed: ${new_failed:-none}) -> rolling back to $prev" >&2
  sudo "$prev/bin/switch-to-configuration" test >/dev/null 2>&1
  exit 4
fi
if [ "$rc" -eq 4 ]; then
  echo "note: exit 4 came only from units already failed before activation: $(printf '%s\n' "$failed_before" | xargs)"
fi

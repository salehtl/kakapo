#!/usr/bin/env bash
# Activate a built system with `switch-to-configuration test`, then watch the
# house's DNS for ~40s and roll back to the running system if AdGuard stops
# answering (3 failed probes in a row). Use it for any change that can touch
# AdGuard or networking -- the whole house resolves through kakapo.
#
#   out=$(nix build --no-link --print-out-paths .#nixosConfigurations.kakapo.config.system.build.toplevel)
#   scripts/guarded-test.sh "$out"
set -u
new=${1:?usage: guarded-test.sh <system store path>}
prev=$(readlink /run/current-system)
dig=$(nix build --no-link --print-out-paths 'nixpkgs#dnsutils^dnsutils')/bin/dig
probe() { "$dig" +short +time=2 +tries=1 @10.0.0.215 one.one.one.one A | grep -q '^[0-9]'; }

probe || { echo "DNS already failing before activation; not activating" >&2; exit 2; }
sudo "$new/bin/switch-to-configuration" test
echo "activation exit $?"
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

#!/usr/bin/env bash
# Activate a built system with `switch-to-configuration test`, then watch the
# house's DNS for ~40s and roll back to the running system if AdGuard stops
# answering (3 failed probes in a row), if the firewall did not load, if any
# unit's reload failed, or if the activation itself failed.
# Use it for any change that can touch AdGuard or networking -- the whole
# house resolves through kakapo.
#
#   out=$(nix build --no-link --print-out-paths .#nixosConfigurations.kakapo.config.system.build.toplevel)
#   scripts/guarded-test.sh "$out"
#   scripts/guarded-test.sh "$out" --replace   # see "Another agent's test" below
#
# Exit codes: 0 pass; 1 DNS/LAN path/firewall went down, rolled back; 2
# already failing, nothing activated; 3 something else replaced the system
# mid-check; 4 firewall/reload/new failed unit, rolled back; 5 gave up on the
# lock; 6 another test activation is live, nothing activated.
set -u
new=$(readlink -f "${1:?usage: guarded-test.sh <system store path> [--replace]}")
replace=0
case ${2:-} in
--replace) replace=1 ;;
'') ;;
*) echo "usage: guarded-test.sh <system store path> [--replace]" >&2; exit 64 ;;
esac

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

# Another agent's test. The lock only serializes runs; a test that finished
# stays live until the next activation, and replacing it silently undoes
# that agent's work (2026-10-26: a docs PR's test stopped nook-scan and
# nook-web, and the GC then deleted the nook system). When the running
# system is not the boot default, some test is live: refuse unless the
# caller checked whose it is (its own, or Saleh agreed) and passed --replace.
# Re-activating the running system itself is always fine.
cur=$(readlink -f /run/current-system)
boot=$(readlink -f /nix/var/nix/profiles/system)
if [ "$cur" != "$boot" ] && [ "$new" != "$cur" ] && [ "$replace" = 0 ]; then
  {
    echo "a test activation is live: $cur"
    echo "  (boot default: $boot)"
    gone=$(comm -23 <(find "$cur/etc/systemd/system/" -maxdepth 1 -printf "%f\n" | sort) <(find "$new/etc/systemd/system/" -maxdepth 1 -printf "%f\n" | sort) | xargs)
    [ -z "$gone" ] || echo "  units it has that $new would remove: $gone"
    echo "Find whose test it is (gh pr list, the closure diff). If it is yours, or"
    echo "Saleh agrees to replace it, re-run with --replace. Nothing was activated."
  } >&2
  exit 6
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
    sudo iptables -C nixos-fw -i "$lan" -p tcp --dport 443 -j nixos-fw-accept 2>/dev/null &&
    firewall_attached
}
# nixos-fw's rules prove nothing on their own: when firewall-start fails
# part-way they are left in a chain INPUT no longer jumps to, and INPUT then
# accepts everything (2026-10-12: the checks above passed throughout).
firewall_attached() {
  sudo iptables -C INPUT -j nixos-fw 2>/dev/null &&
    sudo ip6tables -C INPUT -j nixos-fw 2>/dev/null
}
# What switch-to-configuration counts as failed.
failed_units() { systemctl list-units --state=failed,auto-restart --plain --no-legend | cut -d' ' -f1 | sort; }

probe || { echo "DNS, the LAN path or the firewall already failing before activation; not activating" >&2; exit 2; }
failed_before=$(failed_units)
started=$(date '+%Y-%m-%d %H:%M:%S')
sudo "$new/bin/switch-to-configuration" test
rc=$?
echo "activation exit $rc"

# A firewall that fails to load does not stop DNS, and does not fail a unit:
# a failed reload runs firewall-stop, leaves firewall.service active, and
# switch-to-configuration exits 4 with no newly failed unit. On 2026-10-12
# that passed this script while kakapo had no firewall. So check at once,
# before the watch: the reload's own message, and INPUT's jump to nixos-fw.
if sudo journalctl -q -u firewall.service --since "$started" --no-pager -o cat | grep -q 'Failed to reload firewall' ||
  ! firewall_attached; then
  echo "FIREWALL DID NOT LOAD (activation exit $rc) -> rolling back to $prev" >&2
  sudo journalctl -q -u firewall.service --since "$started" --no-pager -o cat | tail -n 5 >&2
  sudo "$prev/bin/switch-to-configuration" test >/dev/null 2>&1
  # The rollback reloads the firewall only if its unit changed.
  firewall_attached || sudo systemctl restart firewall.service
  if firewall_attached; then echo "rolled back; firewall attached" >&2; else echo "ROLLBACK DID NOT RESTORE THE FIREWALL (INPUT does not jump to nixos-fw): systemctl status firewall" >&2; fi
  exit 4
fi

# Any other reload that failed. A unit whose reload fails stays active on its
# OLD config, so nothing is newly failed and switch-to-configuration exits 4:
# a failed nginx reload keeps the previous vhosts live while the test looks
# clean. PID 1 logs "Reload failed for <unit description>." for each one.
reload_failed=$(sudo journalctl -q --since "$started" --no-pager -o cat _PID=1 | grep '^Reload failed for ' | sort -u)
if [ -n "$reload_failed" ]; then
  echo "A RELOAD FAILED (activation exit $rc) -> rolling back to $prev:" >&2
  printf '%s\n' "$reload_failed" | sed 's/^/  /' >&2
  sudo "$prev/bin/switch-to-configuration" test >/dev/null 2>&1
  echo "rolled back (exit $?)" >&2
  exit 4
fi

fails=0
for i in $(seq 1 20); do
  if probe; then fails=0; else
    fails=$((fails + 1))
    echo "probe $i failed ($fails in a row)"
  fi
  if [ "$fails" -ge 3 ]; then
    echo "DNS, the LAN path or the firewall DOWN -> rolling back to $prev" >&2
    sudo "$prev/bin/switch-to-configuration" test >/dev/null 2>&1
    if probe; then echo "rolled back; DNS answering, firewall attached" >&2; else echo "ROLLBACK DID NOT RESTORE DNS OR THE FIREWALL: systemctl restart adguardhome (or firewall)" >&2; fi
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

# A failed activation can leave the host broken while DNS still answers.
# Exit 4 means units failed; only those that were not already failed before
# count against this test.
new_failed=$(comm -13 <(printf '%s\n' "$failed_before") <(failed_units) | xargs)
if [ "$rc" -ne 0 ] && { [ "$rc" -ne 4 ] || [ -n "$new_failed" ]; }; then
  echo "ACTIVATION FAILED (exit $rc; newly failed: ${new_failed:-none}) -> rolling back to $prev" >&2
  sudo "$prev/bin/switch-to-configuration" test >/dev/null 2>&1
  exit 4
fi
# Exit 4 with no newly failed unit and no failed reload (both checked above):
# units that were already failed before activation.
if [ "$rc" -eq 4 ]; then
  echo "note: exit 4 with no newly failed unit and no failed reload: units already failed before activation ($(printf '%s\n' "$failed_before" | xargs))"
fi

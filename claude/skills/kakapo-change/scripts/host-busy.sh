#!/usr/bin/env bash
# Read-only check: is it safe to start a guarded test activation on kakapo now?
# Prints one line per check and exits 0 when the host looks idle, 1 when
# something else is activating. A live test activation is only a NOTE.
# It changes nothing; scripts/guarded-test.sh still takes the real lock.
set -u
busy=0
lock=/tmp/kakapo-guarded-test.lock

if [ -e "$lock" ] && ! flock -n "$lock" true 2>/dev/null; then
  echo "BUSY  guarded-test lock is held: another agent is testing (guarded-test.sh will wait up to 15 min)"
  busy=1
else
  echo "ok    guarded-test lock is free"
fi

state=$(systemctl is-active nixos-upgrade.service 2>/dev/null)
if [ "$state" = activating ] || [ "$state" = active ]; then
  echo "BUSY  nixos-upgrade.service is $state: the 04:00 autoUpgrade is switching to master; wait for it"
  busy=1
else
  echo "ok    nixos-upgrade.service is $state"
fi

# The timer fires at exactly 04:00 (no randomized delay) and does not take the
# guarded-test lock, so a test started a few minutes before is replaced mid-watch.
next=$(systemctl show nixos-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null)
next_s=$(date -d "$next" +%s 2>/dev/null || echo 0)
now_s=$(date +%s)
if [ "$next_s" -gt "$now_s" ] && [ $((next_s - now_s)) -lt 600 ]; then
  echo "BUSY  nixos-upgrade.timer fires at $next (under 10 min): wait until the upgrade finishes"
  busy=1
else
  echo "ok    nixos-upgrade.timer next fires at ${next:-unknown}"
fi

# Match the program itself (argv 0-2, to cover `sudo` and an interpreter), not
# any command line that merely mentions it, such as the shell running this.
stc=$(ps -eo pid=,args= | awk '{for (i = 2; i <= 4 && i <= NF; i++) if ($i ~ /\/switch-to-configuration(-ng)?$/) { print; next }}')
if [ -n "$stc" ]; then
  echo "BUSY  a switch-to-configuration process is running:"
  printf '%s\n' "$stc" | sed 's/^/        /'
  busy=1
else
  echo "ok    no switch-to-configuration process"
fi

cur=$(readlink -f /run/current-system)
boot=$(readlink -f /nix/var/nix/profiles/system)
if [ "$cur" != "$boot" ]; then
  echo "NOTE  running system differs from the boot default: a test activation (maybe another agent's branch) is live"
  echo "        current: $cur"
  echo "        default: $boot"
else
  echo "ok    running system is the boot default ($cur)"
fi

exit "$busy"

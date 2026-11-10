# The 04:00 upgrade (nixos-upgrade.service; packaged by
# modules/guarded-upgrade.nix, which sets GUARD and INSTALLABLE and the PATH).
# Build master, activate it through scripts/guarded-test.sh, and make it the
# boot default only if the guard passed. The guard rolls the running system
# back itself; a non-zero exit here fails the unit, which mails and pushes
# through notify-failure@.
#
#   kakapo-guarded-upgrade            # what the timer runs: build master
#   kakapo-guarded-upgrade <system>   # root, by hand: an already built system
#
# Exit codes: 0 upgraded, or nothing to do; 1-6 are guarded-test.sh's own
# (1 and 4: activated, broke, rolled back; 2: DNS, the LAN path or the
# firewall was already failing, nothing activated; 3: something else replaced
# the system mid-check; 5: the guard lock stayed busy for 15 minutes);
# 7 the build failed; 8 the guard passed but the boot default was not set.
profile=/nix/var/nix/profiles/system

if [ $# -ge 1 ]; then
  out=$(readlink -f "$1")
  [ -x "$out/bin/switch-to-configuration" ] || { echo "not a system: $1" >&2; exit 64; }
else
  out=$(nix build --no-link --print-out-paths --refresh -L "$INSTALLABLE") || {
    echo "UPGRADE FAILED: could not build $INSTALLABLE; nothing activated" >&2
    exit 7
  }
fi
cur=$(readlink -f /run/current-system)
boot=$(readlink -f "$profile")
echo "new system:   $out"
echo "running:      $cur"
echo "boot default: $boot"

if [ "$out" = "$cur" ] && [ "$out" = "$boot" ]; then
  echo "already running and the boot default: nothing to do"
  exit 0
fi

# A test activation lasts until 04:00 (CLAUDE.md, "Making a change"): master
# replaces it here, so --replace. If master then fails the guard, the host
# goes back to that test system, and the alert below says so.
[ "$cur" = "$boot" ] || echo "a test activation is live; replacing it with master"

rc=0
"$BASH" "$GUARD" "$out" --replace || rc=$?
if [ "$rc" -ne 0 ]; then
  {
    case $rc in
    1 | 4) echo "UPGRADE ROLLED BACK (guarded-test.sh exit $rc): $out broke DNS, the LAN path, the firewall, a reload or a unit." ;;
    2) echo "UPGRADE SKIPPED (guarded-test.sh exit 2): DNS, the LAN path or the firewall was failing before the upgrade; nothing activated." ;;
    3) echo "UPGRADE NOT CONFIRMED (guarded-test.sh exit 3): something else replaced the system during the check." ;;
    5) echo "UPGRADE SKIPPED (guarded-test.sh exit 5): another guarded test held the lock for 15 minutes; nothing activated." ;;
    *) echo "UPGRADE FAILED (guarded-test.sh exit $rc)." ;;
    esac
    echo "running now:  $(readlink -f /run/current-system)"
    echo "boot default: $(readlink -f "$profile") (unchanged)"
    [ "$cur" = "$boot" ] || echo "note: the system running before the upgrade was a test activation, not the boot default"
    echo "master must be fixed (revert PR) or this repeats at the next 04:00."
  } >&2
  exit "$rc"
fi

# Passed. Only now does a reboot get the new system.
if [ "$(readlink -f /run/current-system)" != "$out" ]; then
  echo "UPGRADE NOT CONFIRMED: $out passed the guard but is no longer the running system; boot default unchanged" >&2
  exit 3
fi
if ! nix-env -p "$profile" --set "$out" || ! "$out/bin/switch-to-configuration" boot; then
  echo "UPGRADE INCOMPLETE: $out runs and passed the guard, but could not be made the boot default" >&2
  exit 8
fi
echo "upgraded: $out runs and is the boot default"

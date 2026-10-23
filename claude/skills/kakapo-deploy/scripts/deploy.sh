#!/usr/bin/env bash
# Deploy one merged kakapo commit to the host: SKILL.md steps 4 to 6 in one
# run. It never merges; run it only after Saleh's merge word and pr-gate.sh.
#
#   deploy.sh <squash sha> [--base <pre-merge master sha>] [--near-upgrade]
#
# Steps, each a hard stop on failure:
#   1. <sha> is on master; nixos-upgrade is not running; 04:00 is >30 min away
#      (--near-upgrade overrides that, only on Saleh's word).
#   2. Fetch scripts/guarded-test.sh from <base> (default <sha>^, the pre-merge
#      master of a squash merge), so a merged PR cannot weaken its own guard.
#   3. Build github:salehtl/kakapo/<sha> and print the closure diff.
#   4. Activate it through that guard copy.
#   5. Health: still the running system, AdGuard answers, no new failed unit,
#      core units active, the LAN proxy answers, and hasala verify.sh when
#      the hasalad binary changed.
#   6. Make it the boot default, then watch master CI for <sha>.
#
# Exit codes: 0 deployed and master CI green; 1 a precondition failed,
# nothing activated; 2 the build failed; 3 guarded-test.sh failed (it rolled
# back itself, or refused); 4 health failed after activation: the new system
# runs but is NOT the boot default (roll back, references/rollback.md);
# 5 another activation replaced ours, or the guard lock was busy; 6 deployed
# and boot default set, but master CI is red: an emergency before 04:00.
# 64 usage.
set -uo pipefail
repo=salehtl/kakapo
usage() { echo "usage: deploy.sh <sha> [--base <sha>] [--near-upgrade]" >&2; exit 64; }
sha=${1:-}
[[ $sha =~ ^[0-9a-f]{7,40}$ ]] || usage
shift
base=''
near=0
while [ $# -gt 0 ]; do
  case $1 in
  --base) base=${2:-}; [[ $base =~ ^[0-9a-f]{7,40}$ ]] || usage; shift 2 ;;
  --near-upgrade) near=1; shift ;;
  *) usage ;;
  esac
done

say() { printf '%s\t%s\n' "$1" "$2"; }
die() { say FAIL "$2"; exit "$1"; }

# 1. Preconditions.
full=$(gh api "repos/$repo/commits/$sha" --jq .sha 2>/dev/null) || die 1 "unknown commit $sha"
sha=$full
st=$(gh api "repos/$repo/compare/$sha...master" --jq .status) || die 1 "cannot compare $sha with master"
case $st in identical | ahead) ;; *) die 1 "$sha is not on master ($st)" ;; esac
[ "$st" = identical ] || say WARN "master moved past $sha; deploying $sha only"
[ "$(systemctl show -p ActiveState --value nixos-upgrade.service)" != activating ] ||
  die 1 "nixos-upgrade.service is running; wait for it"
next=$(systemctl show -p NextElapseUSecRealtime --value nixos-upgrade.timer)
if [ -n "$next" ] && left=$(($(date -d "$next" +%s) - $(date +%s))) && [ "$left" -lt 1800 ] && [ $near = 0 ]; then
  die 1 "the 04:00 upgrade starts in $((left / 60)) min; use --near-upgrade only on Saleh's word"
fi
prev_run=$(readlink /run/current-system)
prev_boot=$(readlink -f /nix/var/nix/profiles/system)
failed_before=$(systemctl --failed --no-legend --plain | awk '{print $1}' | sort)
[ "$prev_run" = "$prev_boot" ] || say INFO "a test activation is live ($prev_run); this deploy replaces it"
say OK "commit $sha; rollback target $prev_boot"

# 2. Pre-merge guard copy.
[ -n "$base" ] || base=$(gh api "repos/$repo/commits/$sha" --jq '.parents[0].sha') || die 1 "no parent for $sha"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if ! gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/scripts/guarded-test.sh?ref=$base" >"$tmp/guarded-test.sh" ||
  [ ! -s "$tmp/guarded-test.sh" ]; then
  die 1 "cannot fetch guarded-test.sh at $base"
fi
chmod +x "$tmp/guarded-test.sh"
say OK "guard from ${base:0:7}"

# 3. Build.
out=$(nix build --no-link --print-out-paths \
  "github:$repo/$sha#nixosConfigurations.kakapo.config.system.build.toplevel") || die 2 "build of $sha failed"
say OK "built $out"
echo "---- closure diff"
nix store diff-closures "$prev_run" "$out"
echo "----"

# 4. Guarded activation.
"$tmp/guarded-test.sh" "$out"
rc=$?
case $rc in
0) say OK "guarded-test.sh passed" ;;
5) die 5 "guard lock busy for 15 min; try later" ;;
*) die 3 "guarded-test.sh exit $rc (see SKILL.md step 4); boot default unchanged" ;;
esac

# 5. Health. Any failure stops before the boot default.
bad=0
chk() {
  local msg=$1
  shift
  if "$@" >/dev/null 2>&1; then say OK "$msg"; else say FAIL "$msg"; bad=1; fi
}
[ "$(readlink /run/current-system)" = "$out" ] ||
  die 5 "another activation replaced $out; re-run deploy.sh"
chk "AdGuard answers on 10.0.0.215" host -W 2 one.one.one.one 10.0.0.215
for u in adguardhome nginx sshd tailscaled; do
  chk "$u active" systemctl is-active --quiet "$u"
done
chk "LAN proxy answers" [ "$(curl -s --max-time 5 https://kakapo.salehtl.com)" = kakapo ]
new_failed=$(comm -13 <(printf '%s\n' "$failed_before") \
  <(systemctl --failed --no-legend --plain | awk '{print $1}' | sort) | xargs)
if [ -n "$new_failed" ]; then say FAIL "new failed units: $new_failed"; bad=1; else say OK "no new failed units"; fi
hd() { grep -o '/nix/store/[^ ;]*hasalad[^ ;/]*' "$1/etc/systemd/system/hasalad.service" 2>/dev/null | head -1; }
if [ "$(hd "$prev_run")" != "$(hd "$out")" ]; then
  verify=$(dirname "$(readlink -f "$0")")/../../hasala-release/scripts/verify.sh
  echo "---- hasala verify.sh"
  if "$verify" "$out"; then say OK "hasala verify.sh"; else say FAIL "hasala verify.sh"; bad=1; fi
  echo "----"
fi
[ $bad = 0 ] || die 4 "health failed: $out runs but is not the boot default; roll back to $prev_boot"

# 6. Boot default, then master CI.
[ "$(readlink /run/current-system)" = "$out" ] ||
  die 5 "another activation replaced $out; re-run deploy.sh"
if ! sudo -n nix-env -p /nix/var/nix/profiles/system --set "$out" >/dev/null ||
  ! sudo -n "$out/bin/switch-to-configuration" boot >/dev/null; then
  die 4 "could not set the boot default"
fi
[ "$(readlink -f /nix/var/nix/profiles/system)" = "$out" ] || die 4 "boot default is not $out"
say OK "boot default $(readlink /nix/var/nix/profiles/system)"
for f in kernel initrd; do
  [ "$(readlink -f "/run/booted-system/$f")" = "$(readlink -f "$out/$f")" ] ||
    say WARN "$f changed: a reboot is needed to use it (Saleh's call)"
done

run=
for _ in $(seq 1 30); do
  run=$(gh run list --repo "$repo" --workflow check.yml --branch master --event push --limit 10 \
    --json databaseId,headSha --jq ".[] | select(.headSha == \"$sha\") | .databaseId" | head -1)
  [ -n "$run" ] && break
  sleep 10
done
[ -n "$run" ] || die 6 "no master CI run found for $sha"
gh run watch "$run" --repo "$repo" --exit-status >/dev/null 2>&1 ||
  die 6 "master CI run $run is red: the 04:00 upgrade will fail; open a revert PR"
say OK "master CI run $run passed"
say DEPLOYED "$sha $out"

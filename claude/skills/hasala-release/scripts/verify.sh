#!/usr/bin/env bash
# Hasala checks after an activation on kakapo (test or deploy). Needs sudo for
# hasala-health and hasala-admin; it changes nothing except running the
# hasala-health probe once.
#
#   verify.sh <built system toplevel, e.g. $out, or "-">
#
# Prints one "PASS|FAIL <check>" line per check. Exit 0 only if all pass.
set -uo pipefail
sys=${1:--}
exe() { grep -o '/nix/store/[^ ;]*hasalad[^ ;/]*' | head -1; }
rc=0
chk() {
  local msg=$1
  shift
  if "$@"; then echo "PASS $msg"; else echo "FAIL $msg"; rc=1; fi
}

for u in hasala-postgresql hasalad cloudflared-hasala hasala-console; do
  chk "$u active" [ "$(systemctl is-active "$u")" = active ]
done

r=$(systemctl show -p Result --value hasala-migrate.service)
chk "hasala-migrate result=$r" [ "$r" = success ]
echo "---- hasala-migrate (last run)"
journalctl -u hasala-migrate.service -n 60 --no-pager -o cat 2>/dev/null |
  grep -v '^Starting \|^Finished \|^hasala-migrate.service: ' | tail -6
echo "----"

have=$(systemctl show -p ExecStart --value hasalad.service | exe)
if [ "$sys" != - ]; then
  want=$(exe <"$sys/etc/systemd/system/hasalad.service")
  chk "hasalad is $have" [ "$have" = "$want" ]
else
  echo "INFO hasalad is $have"
fi
sudo hasala-admin version 2>&1 | sed 's/^/INFO version: /'

code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://api.hasala.app/api/v1/healthz)
chk "public healthz $code" [ "$code" = 200 ]
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://api.hasala.app/api/v1/meta)
chk "public meta $code" [ "$code" = 200 ]
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' https://api.hasala.app/not-allowlisted)
chk "tunnel allowlist 404 ($code)" [ "$code" = 404 ]

sudo systemctl start hasala-health.service
r=$(systemctl show -p Result --value hasala-health.service)
chk "hasala-health result=$r" [ "$r" = success ]
[ "$r" = success ] || journalctl -u hasala-health.service -n 20 --no-pager -o cat

failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | grep -i hasala || true)
chk "no failed hasala units${failed:+: $failed}" [ -z "$failed" ]
exit "$rc"

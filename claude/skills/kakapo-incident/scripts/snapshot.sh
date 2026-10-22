#!/usr/bin/env bash
# Read-only incident snapshot for kakapo, in triage order: DNS, network and
# reachability, proxy, units, disk, autoUpgrade, boot. It changes nothing:
# no restarts, no activations, no writes outside stdout. sudo is used only
# for reads (iptables -C, journalctl) and with -n, so it never prompts.
#
#   bash snapshot.sh            # whole snapshot
#   bash snapshot.sh > "$scratch/incident-$(date +%F-%H%M).txt"
#
# Every check prints OK, FAIL or a value; nothing aborts the run, because an
# incident snapshot is most useful when part of the host is broken.
set -u
lan=enp4s0 # LAN NIC (modules/services/adguard.nix, lan-proxy.nix)
addr=10.0.0.215 # kakapo's fixed LAN address (lanAddress in lan-proxy.nix)

hdr() { printf '\n=== %s\n' "$*"; }
# label is passed per call as an environment prefix: label="..." ok cmd args
# shellcheck disable=SC2154
ok() { if "$@" >/dev/null 2>&1; then echo "OK   $label"; else echo "FAIL $label"; fi; }

hdr "time and system"
date -Is
echo "running: $(readlink /run/current-system)"
echo "booted:  $(readlink /run/booted-system)"
echo "default: $(readlink /nix/var/nix/profiles/system) -> $(readlink -f /nix/var/nix/profiles/system)"
if [ "$(readlink /run/booted-system/kernel)" = "$(readlink /run/current-system/kernel)" ]; then
  echo "kernel: booted = running"
else
  echo "kernel: DIFFERS (booted $(readlink /run/booted-system/kernel), running $(readlink /run/current-system/kernel))"
fi
echo "uptime: $(uptime)"
run=$(readlink /run/current-system)
[ "$run" = "$(readlink -f /nix/var/nix/profiles/system)" ] ||
  echo "NOTE running is not the boot default: a test activation is live"
gen=
for l in /nix/var/nix/profiles/system-*-link; do
  [ "$(readlink "$l")" = "$run" ] && gen=$l
done
echo "running generation: ${gen:-none (an unmerged test build)}"
# guarded-test.sh holds this lock for its whole run; a free lock means no test
# is in progress. Taking it here with -n is released at once.
if [ -e /tmp/kakapo-guarded-test.lock ]; then
  (flock -n 9 && echo "guarded-test lock: free" || echo "guarded-test lock: HELD (another agent is testing)") 9</tmp/kakapo-guarded-test.lock
fi

hdr "1. DNS (AdGuard serves the whole house)"
echo "adguardhome: $(systemctl is-active adguardhome.service)"
label="AdGuard answers on $addr" ok sh -c "host -W 2 -t A one.one.one.one $addr | grep -q 'has address'"
label="$addr is on $lan" ok sh -c "ip -4 -o addr show dev $lan | grep -q ' ${addr//./\\.}/'"
label="firewall opens udp/53 on $lan" ok sudo -n iptables -C nixos-fw -i "$lan" -p udp --dport 53 -j nixos-fw-accept
label="kakapo's own resolver (1.1.1.2 pin) resolves github.com" ok sh -c "host -W 3 -t A github.com | grep -q 'has address'"
echo "--- dns-health, last 6 lines with a problem:"
journalctl -u dns-health.service --since -1d --no-pager -o short-iso 2>/dev/null |
  grep -E 'failure [0-9]+ in a row|not answer|not on|does not open|mail failed' | tail -n 6
echo "--- adguardhome journal, last 10:"
journalctl -u adguardhome.service -n 10 --no-pager -o short-iso 2>/dev/null | cut -c1-220

hdr "2. network, firewall, Tailscale, SSH"
ip -4 -o addr show dev "$lan" | awk '{print "lan: " $4}'
ip route show default | sed 's/^/route: /'
label="INPUT jumps to nixos-fw (IPv4)" ok sudo -n iptables -C INPUT -j nixos-fw
label="INPUT jumps to nixos-fw (IPv6)" ok sudo -n ip6tables -C INPUT -j nixos-fw
label="firewall opens tcp/443 on $lan" ok sudo -n iptables -C nixos-fw -i "$lan" -p tcp --dport 443 -j nixos-fw-accept
# tailscaled-set is a oneshot: "inactive (success)" is its healthy state.
for u in firewall sshd tailscaled tailscaled-set; do
  echo "$u: $(systemctl is-active "$u.service") ($(systemctl show -p Result --value "$u.service"))"
done
tailscale status 2>&1 | head -n 4
echo "--- subnet route (should list $addr/32):"
tailscale status --json 2>/dev/null | grep -A2 PrimaryRoutes
# Expected: 22 (sshd, all), 53 (AdGuard), 10.0.0.215:443 (nginx), and
# tailscaled's and cloudflared's own sockets. Anything else is a finding.
echo "--- non-loopback listeners:"
sudo -n ss -Hlntup 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\])/ {print $1, $5, $7}' | sort -u
echo "--- nixos-fw accept rules (IPv4, then IPv6):"
sudo -n iptables -S nixos-fw 2>&1 | grep -- '-j nixos-fw-accept'
sudo -n ip6tables -S nixos-fw 2>&1 | grep -- '-j nixos-fw-accept'
echo "--- sshd logins, last 3 days:"
journalctl -u sshd.service --since -3d --no-pager -o short-iso 2>/dev/null |
  grep -E 'Accepted|Invalid user|Failed' | tail -n 10

hdr "3. LAN proxy (nginx on $addr:443)"
echo "nginx: $(systemctl is-active nginx.service)"
body=$(curl -s --max-time 5 --resolve "kakapo.salehtl.com:443:$addr" https://kakapo.salehtl.com/ 2>&1)
if [ "$body" = kakapo ]; then echo "OK   https://kakapo.salehtl.com/ returns kakapo"; else echo "FAIL https://kakapo.salehtl.com/ returned: ${body:0:120}"; fi
curl -sv --max-time 5 -o /dev/null --resolve "kakapo.salehtl.com:443:$addr" https://kakapo.salehtl.com/ 2>&1 |
  sed -n 's/^\*  *expire date: /cert expires: /p'
for u in lan-proxy-dns lan-proxy-spoof-check acme-order-renew-salehtl.com tailscale-nginx-auth; do
  echo "$u: $(systemctl is-active "$u.service") ($(systemctl show -p Result --value "$u.service"))"
done

hdr "4. failed units"
failed=$(systemctl list-units --state=failed,auto-restart --plain --no-legend)
echo "${failed:-none}"
echo "--- local health endpoints:"
echo "ledger: HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8090/api/health)"
# hasala-api-out resets every local connection to :8471 except root's and
# hasala's own users, so this probe must run as root (a read).
echo "hasalad: HTTP $(sudo -n curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8471/api/v1/healthz)"

hdr "5. disk"
df -h / /boot /mnt/media 2>&1
df -i / | tail -n 1 | awk '{print "inodes on /: " $5 " used"}'
findmnt -n /mnt/media >/dev/null && echo "OK   /mnt/media mounted" || echo "FAIL /mnt/media not mounted"
journalctl --disk-usage 2>/dev/null

hdr "6. autoUpgrade (04:00 daily)"
systemctl show -p Result,ExecMainStatus,ExecMainExitTimestamp nixos-upgrade.service
systemctl list-timers nixos-upgrade.timer --no-pager --plain --no-legend
echo "--- nixos-upgrade, last 7 days, errors:"
journalctl -u nixos-upgrade.service --since -7d --no-pager -o short-iso 2>/dev/null |
  grep -iE 'error|fail|warning: (unable|could not)' | tail -n 8

hdr "7. generations and recent activations"
sudo -n nixos-rebuild list-generations 2>/dev/null | head -n 6
echo "--- activations, last 3 days (time -> store path):"
sudo -n journalctl --since -3d --no-pager -o short-iso -t nixos 2>/dev/null |
  grep 'finished switching to system configuration' | tail -n 6

hdr "8. boot"
journalctl --list-boots --no-pager 2>/dev/null | tail -n 3
# Known noise is filtered: dbus-broker duplicate-name lines and Docker
# container output (tag = 12-hex container id; grampsweb's celery logs INFO at
# err). Container health shows in section 4's failed units instead.
echo "--- errors this boot (priority err, known noise removed), last 15:"
journalctl -b -p err --no-pager -o short-iso 2>/dev/null |
  grep -vE 'Ignoring duplicate name| kakapo [0-9a-f]{12}\[' | tail -n 15

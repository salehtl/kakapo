#!/usr/bin/env bash
# kakapo health check. READ-ONLY: it never starts, stops, restarts, activates,
# collects garbage, writes config or sends a notification. It only reads.
#
# Output: one tab-separated line per check, then one summary line:
#
#   <STATUS>\t<check>\t<detail>
#   SUMMARY\t<worst STATUS>\tok=N warn=N fail=N skip=N
#
# STATUS is OK, WARN, FAIL or SKIP (could not run: no root, no network, no gh
# auth). Exit code: 0 all OK/SKIP, 1 worst is WARN, 2 worst is FAIL, 64 usage
# (unknown argument or --only name, or no check ran).
# A future systemd timer can run this as root and push WARN/FAIL lines to ntfy
# (POST to http://127.0.0.1:2586/kakapo, as notify-failure@ does); this script
# itself never does. Such a unit must:
#   - set SuccessExitStatus = "1 2" and read the WARN/FAIL lines itself, or
#     notify-failure@ fires a duplicate alert and failed_units flags the unit;
#   - run --offline (plus at most a daily online run), so it never polls GitHub;
#   - put on `path` (procps before coreutils, for uptime -s): procps bind.host diffutils curl smartmontools util-linux iproute2 gawk
#     gnused gnugrep coreutils findutils systemd, networking.firewall.package,
#     services.tailscale.package, nix.package (and gh for online runs).
#
# Usage: check.sh [--offline] [--deep] [--only name,name,...]
#   --offline  skip checks that need GitHub (master eval, PRs, master CI)
#   --deep     also measure /nix/store with du (about 90 s)
#   --only     run only the named checks (see CHECKS below)
#
# Host facts used here (keep in sync with the flake):
#   LAN address 10.0.0.215 on enp4s0  modules/services/lan-proxy.nix, adguard.nix
#   proxy names = /etc/hosts line for 10.0.0.215 (networking.hosts, lan-proxy.nix)
#   wildcard cert *.salehtl.com, unit acme-salehtl.com  lan-proxy.nix
#   nixos-upgrade at 04:00, nix-gc weekly                modules/base.nix
#   nixpkgs-age threshold 21 days                         modules/notify.nix
#   KEY_UNITS below                                       modules/services/*.nix
set -u
export LC_ALL=C

LAN_ADDR=10.0.0.215
LAN_IF=enp4s0
ZONE=salehtl.com
FLAKE=github:salehtl/kakapo
REPO=salehtl/kakapo

# Units that must be active, from modules/services/*.nix, base.nix, notify.nix.
# A unit missing here means the list drifted from the flake: the check WARNs.
KEY_UNITS=(
  sshd.service tailscaled.service
  adguardhome.service dns-health.timer
  nginx.service tailscale-nginx-auth.service acme-renew-salehtl.com.timer
  lan-proxy-dns.service lan-proxy-spoof-check.timer
  prometheus.service grafana.service prometheus-node-exporter.service
  prometheus-smartctl-exporter.service prometheus-nvidia-gpu-exporter.service
  immich-server.service immich-machine-learning.service postgresql.service redis-immich.service
  docker.service docker-grampsweb.service docker-grampsweb-celery.service docker-grampsweb-redis.service
  ledger.service ntfy-sh.service zapret.service
  nixos-upgrade.timer nix-gc.timer nixpkgs-age.timer tailscale-key-expiry.timer
)

# Hasala has its own check: hasala.target is a kill switch Saleh may pull on
# purpose (modules/services/hasala.nix), so it must not hide core units.
HASALA_UNITS=(
  hasalad.service hasala-console.service hasala-postgresql.service cloudflared-hasala.service
  hasala-health.timer hasala-backup.timer hasala-backup-check.timer hasala-email-token-check.timer
)

# Backup dirs (both 0700, so root only) and the newest file pattern in each.
BACKUPS=(
  "/mnt/media/immich/backups:immich-db-backup-*.sql.gz" # Immich internal job, 02:00 daily
  "/mnt/media/hasala-backup:hasala-daily-*.dump.age"    # hasala-backup.timer, 03:15 daily
)

CHECKS=(dns upgrade failed_units nixpkgs_age generation reboot disk backups gc smart memory tls proxy services hasala tailscale prs)

offline=0 deep=0 only=
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) offline=1 ;;
    --deep) deep=1 ;;
    --only) only=${2:?--only needs a list}; shift ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
if [ -n "$only" ]; then
  for o in ${only//,/ }; do
    [[ " ${CHECKS[*]} " == *" $o "* ]] || { echo "unknown check: $o (known: ${CHECKS[*]})" >&2; exit 64; }
  done
fi

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo -n); fi
can_root() { [ ${#SUDO[@]} -eq 0 ] || sudo -n true 2>/dev/null; }
have() { command -v "$1" >/dev/null 2>&1; }

nok=0 nwarn=0 nfail=0 nskip=0
emit() {
  # emit STATUS check detail...
  local s=$1 c=$2; shift 2
  local d="$*"
  d=${d//$'\t'/ }; d=${d//$'\n'/; }
  printf '%s\t%s\t%s\n' "$s" "$c" "$d"
  case "$s" in OK) nok=$((nok + 1)) ;; WARN) nwarn=$((nwarn + 1)) ;; FAIL) nfail=$((nfail + 1)) ;; *) nskip=$((nskip + 1)) ;; esac
}
now=$(date +%s)
age_h() { echo $(((now - $1) / 3600)); }

# --- nixos-upgrade.service: last result, failures in 7 days, last success age
# Epoch of the last successful nixos-upgrade in the 7-day journal, or empty.
upgrade_last_success() {
  journalctl -u nixos-upgrade.service --since -7d -q -o short-unix --no-pager 2>/dev/null |
    grep "Finished NixOS Upgrade" | tail -1 | cut -d' ' -f1 | cut -d. -f1
}
check_upgrade() {
  local result fails last timer
  timer=$(systemctl is-active nixos-upgrade.timer 2>/dev/null)
  result=$(systemctl show -p Result --value nixos-upgrade.service)
  fails=$(journalctl -u nixos-upgrade.service --since -7d -q -o cat --no-pager 2>/dev/null | grep -c "Failed with result")
  last=$(upgrade_last_success)
  if [ "$timer" != active ]; then
    emit FAIL upgrade "nixos-upgrade.timer is $timer: master will not deploy at 04:00"
  elif [ "$result" != success ]; then
    emit FAIL upgrade "last nixos-upgrade result=$result; $fails failure(s) in 7d"
  elif [ -z "$last" ]; then
    emit WARN upgrade "no successful nixos-upgrade in the last 7d journal; $fails failure(s)"
  elif [ "$(age_h "$last")" -gt 30 ]; then
    emit WARN upgrade "last success $(age_h "$last")h ago (expected daily at 04:00); $fails failure(s) in 7d"
  elif [ "$fails" -gt 0 ]; then
    # The latest run succeeded: an earlier failure has recovered. Report, do not alert.
    emit OK upgrade "last success $(age_h "$last")h ago; $fails failure(s) in 7d (recovered)"
  else
    emit OK upgrade "last success $(age_h "$last")h ago; 0 failures in 7d"
  fi
}

# --- failed systemd units
check_failed_units() {
  local units
  units=$(systemctl list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ')
  if [ -n "$units" ]; then emit FAIL failed_units "$units"; else emit OK failed_units "none"; fi
}

# --- age of the running nixpkgs (same rule as nixpkgs-age.service)
check_nixpkgs_age() {
  local built days
  local built_s
  built=$(cut -d. -f3 </run/current-system/nixos-version 2>/dev/null)
  if ! built_s=$(date -d "$built" +%s 2>/dev/null); then
    emit SKIP nixpkgs_age "cannot parse /run/current-system/nixos-version"; return
  fi
  days=$(((now - built_s) / 86400))
  if [ "$days" -gt 21 ]; then emit FAIL nixpkgs_age "nixpkgs $built is $days days old (limit 21): flake.lock is not reaching the host"
  elif [ "$days" -gt 14 ]; then emit WARN nixpkgs_age "nixpkgs $built is $days days old"
  else emit OK nixpkgs_age "nixpkgs $built, $days days old"; fi
}

# --- running generation vs boot default vs what master builds
check_generation() {
  local cur def master n
  cur=$(readlink -f /run/current-system)
  def=$(readlink -f /nix/var/nix/profiles/system)
  local notes=()
  [ "$cur" != "$def" ] && notes+=("running system is not the boot default (a test activation?): reboot or 04:00 replaces it")
  if [ "$offline" -eq 1 ]; then
    if [ ${#notes[@]} -gt 0 ]; then emit WARN generation "${notes[*]}"; else emit SKIP generation "offline: master not evaluated; running = boot default"; fi
    return
  fi
  if ! master=$(timeout 180 nix eval --raw --refresh "$FLAKE#nixosConfigurations.kakapo.config.system.build.toplevel.outPath" 2>/dev/null); then
    notes+=("could not evaluate $FLAKE master")
    emit WARN generation "${notes[*]}"; return
  fi
  if [ "$cur" = "$master" ]; then
    if [ ${#notes[@]} -gt 0 ]; then emit WARN generation "${notes[*]}"; else emit OK generation "running = boot default = master (${cur#/nix/store/})"; fi
    return
  fi
  if [ -e "$master" ]; then
    n=$(nix store diff-closures "$cur" "$master" 2>/dev/null | grep -c .)
    notes+=("running differs from master: $n closure-diff line(s) (nix store diff-closures $cur $master)")
  else
    notes+=("running differs from master; master toplevel not built here (${master#/nix/store/})")
  fi
  # master moved after the last successful 04:00 run: the next run deploys it.
  local mod last
  mod=$(nix flake metadata --json "$FLAKE" 2>/dev/null | grep -o '"lastModified":[0-9]*' | head -1 | cut -d: -f2)
  last=$(upgrade_last_success)
  if [ "$cur" = "$def" ] && [ -n "$mod" ] && [ -n "$last" ] && [ "$mod" -gt "$last" ]; then
    emit OK generation "master is ahead (changed $(age_h "$mod")h ago, after the last upgrade); the next 04:00 run deploys it"; return
  fi
  emit WARN generation "${notes[*]}"
}

# --- reboot needed: kernel, initrd, kernel modules of booted vs current
check_reboot() {
  local diffs=() f
  for f in kernel initrd kernel-modules; do
    [ "$(readlink -f /run/booted-system/$f)" = "$(readlink -f /run/current-system/$f)" ] || diffs+=("$f")
  done
  # kernel-params is a plain file in the toplevel, so compare its content.
  cmp -s /run/booted-system/kernel-params /run/current-system/kernel-params || diffs+=(kernel-params)
  if [ ${#diffs[@]} -gt 0 ]; then emit WARN reboot "booted ${diffs[*]} differs from current system: reboot needed to use it"
  else emit OK reboot "booted kernel, initrd, modules and params match the current system (up since $(uptime -s))"; fi
}

# --- disk usage of /, /boot, /mnt/media (Immich library, Hasala backups)
check_disk() {
  local worst=OK parts=() mp pct
  for mp in / /boot /mnt/media; do
    if ! mountpoint -q "$mp"; then parts+=("$mp NOT MOUNTED"); worst=FAIL; continue; fi
    pct=$(df --output=pcent "$mp" | tail -1 | tr -dc 0-9)
    parts+=("$mp ${pct}%")
    if [ "$pct" -ge 90 ]; then worst=FAIL; elif [ "$pct" -ge 80 ] && [ "$worst" = OK ]; then worst=WARN; fi
  done
  emit "$worst" disk "${parts[*]}"
}

# --- backups on /mnt/media are fresh (Immich's dump job is not a systemd unit)
check_backups() {
  if ! can_root; then emit SKIP backups "needs root (sudo -n): the backup dirs are 0700"; return; fi
  local e dir pat newest h st=OK parts=()
  for e in "${BACKUPS[@]}"; do
    dir=${e%%:*} pat=${e#*:}
    newest=$("${SUDO[@]}" find "$dir" -maxdepth 1 -type f -name "$pat" -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    if [ -z "$newest" ]; then parts+=("$dir: no $pat"); st=FAIL; continue; fi
    h=$(age_h "$newest")
    parts+=("$dir newest ${h}h old")
    if [ "$h" -gt 72 ]; then st=FAIL; elif [ "$h" -gt 36 ] && [ "$st" = OK ]; then st=WARN; fi
  done
  emit "$st" backups "$(IFS=';'; echo "${parts[*]}")"
}

# --- nix GC: timer, last run, generation count, optional store size
check_gc() {
  local timer last result gens size='' st=OK
  timer=$(systemctl is-active nix-gc.timer 2>/dev/null)
  result=$(systemctl show -p Result --value nix-gc.service)
  last=$(systemctl show -p LastTriggerUSec --value nix-gc.timer)
  gens=$(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | wc -l)
  if [ "$deep" -eq 1 ]; then
    if can_root; then size=" store=$("${SUDO[@]}" du -sxh /nix/store 2>/dev/null | cut -f1)"; else size=" store=? (no root)"; fi
  fi
  local last_s
  last_s=$(date -d "$last" +%s 2>/dev/null || echo 0)
  if [ "$timer" != active ]; then st=FAIL
  elif [ "$result" != success ] || [ "$last_s" -eq 0 ] || [ $((now - last_s)) -gt $((8 * 86400)) ]; then st=WARN; fi
  emit "$st" gc "nix-gc.timer $timer, last run ${last:-never} result=$result; $gens system generations$size"
}

# --- SMART / NVMe health of every disk
check_smart() {
  if ! can_root; then emit SKIP smart "needs root (sudo -n) for smartctl"; return; fi
  if ! have smartctl; then emit SKIP smart "smartctl not on PATH"; return; fi
  local dev out st=OK parts=() h v
  for dev in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
    out=$("${SUDO[@]}" smartctl -H -A "/dev/$dev" 2>&1)
    h=$(grep -o 'test result: [A-Z]*' <<<"$out" | awk '{print $3}')
    grep -q 'SMART Health Status: OK' <<<"$out" && h=PASSED # SAS wording
    local d="$dev ${h:-no SMART health}"
    # No health line (e.g. a USB disk without SAT pass-through) is WARN, not FAIL.
    if [ -z "$h" ]; then [ "$st" = OK ] && st=WARN; elif [ "$h" != PASSED ]; then st=FAIL; fi
    if [[ $dev == nvme* ]]; then
      v=$(awk -F: '/Critical Warning/{gsub(/ /,"",$2);print $2}' <<<"$out"); [ "${v:-0x00}" = 0x00 ] || { st=FAIL; d+=" critical=$v"; }
      v=$(awk -F: '/Percentage Used/{gsub(/[ %]/,"",$2);print $2}' <<<"$out"); d+=" used=${v}%"; [ "${v:-0}" -ge 90 ] && [ "$st" = OK ] && st=WARN
      v=$(awk -F: '/Media and Data Integrity Errors/{gsub(/ /,"",$2);print $2}' <<<"$out"); [ "${v:-0}" -eq 0 ] || { [ "$st" = OK ] && st=WARN; d+=" media_errors=$v"; }
      v=$(awk -F: '/^Temperature:/{gsub(/[^0-9]/,"",$2);print $2}' <<<"$out"); d+=" ${v}C"
    else
      for a in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable Reported_Uncorrect; do
        v=$(awk -v a="$a" '$2==a{print $10}' <<<"$out")
        if [ -n "$v" ] && [ "$v" != 0 ]; then d+=" $a=$v"; [ "$st" = OK ] && st=WARN; fi
      done
    fi
    parts+=("$d")
  done
  emit "$st" smart "$(IFS=';'; echo "${parts[*]}")"
}

# --- memory, load, OOM kills
check_memory() {
  local total avail pct l1 l5 cpus oom st=OK
  total=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
  avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
  pct=$((avail * 100 / total))
  read -r l1 l5 _ </proc/loadavg
  cpus=$(nproc)
  oom=$(journalctl -k --since -24h -q -o cat --no-pager 2>/dev/null | grep -ci "out of memory: killed")
  # systemd-oomd kills whole cgroups and logs in its own unit, not the kernel log.
  oom=$((oom + $(journalctl -u systemd-oomd --since -24h -q -o cat --no-pager 2>/dev/null | grep -ci "killed")))
  [ "$pct" -lt 10 ] && st=WARN
  [ "$pct" -lt 5 ] && st=FAIL
  awk -v l="$l5" -v c="$cpus" 'BEGIN{exit !(l > c)}' && [ "$st" = OK ] && st=WARN
  awk -v l="$l5" -v c="$cpus" 'BEGIN{exit !(l > 2*c)}' && st=FAIL
  [ "$oom" -gt 0 ] && [ "$st" = OK ] && st=WARN
  emit "$st" memory "available ${pct}% of $((total / 1024)) MiB; load $l1/$l5 on $cpus CPUs; $oom OOM kill(s) in 24h"
}

# --- TLS: the wildcard cert nginx actually serves on the LAN address
check_tls() {
  local exp exp_s days acme st
  exp=$(curl -sv -o /dev/null --max-time 10 --resolve "kakapo.$ZONE:443:$LAN_ADDR" "https://kakapo.$ZONE/" 2>&1 |
    sed -n 's/^\*[[:space:]]*expire date: //p' | head -1)
  acme=$(systemctl show -p Result --value "acme-$ZONE.service")
  if [ -z "$exp" ] || ! exp_s=$(date -d "$exp" +%s 2>/dev/null); then
    emit FAIL tls "no valid certificate from https://kakapo.$ZONE/ on $LAN_ADDR:443 (acme-$ZONE result=$acme)"; return
  fi
  days=$(((exp_s - now) / 86400))
  st=OK
  # Let's Encrypt renews about 30 days before expiry; under 21 means renewal is failing.
  [ "$days" -lt 21 ] && st=WARN
  [ "$days" -lt 7 ] && st=FAIL
  [ "$acme" != success ] && [ "$st" = OK ] && st=WARN
  emit "$st" tls "*.$ZONE expires in $days days ($exp); acme-$ZONE result=$acme"
}

# --- AdGuard DNS for the house (critical: every LAN device resolves here)
check_dns() {
  local problems=() notes=() a up
  if have host; then
    # Both names resolve upstream (kakapo.$ZONE is a public Cloudflare record),
    # so tell "AdGuard is down" (timeout, no reply) from "AdGuard answers but
    # upstream fails" (SERVFAIL/REFUSED: the WAN or the upstream resolvers).
    up=$(host -W 3 -t A one.one.one.one "$LAN_ADDR" 2>&1)
    a=$(host -W 3 -t A "kakapo.$ZONE" "$LAN_ADDR" 2>&1 | awk '/has address/{print $4; exit}')
    if grep -q 'has address' <<<"$up"; then
      [ "$a" = "$LAN_ADDR" ] || problems+=("kakapo.$ZONE resolved to '${a:-nothing}', want $LAN_ADDR")
    elif grep -q 'SERVFAIL\|REFUSED' <<<"$up"; then
      problems+=("AdGuard answers, but upstream lookups fail ($(grep -o 'SERVFAIL\|REFUSED' <<<"$up" | head -1)): check the WAN or upstream resolvers, not AdGuard")
    else
      problems+=("AdGuard on $LAN_ADDR does not answer")
    fi
    host -T -W 3 -t A "kakapo.$ZONE" "$LAN_ADDR" 2>/dev/null | grep -q 'has address' || problems+=("no answer over TCP/53")
  else
    notes+=("queries not run: host(1) not on PATH")
  fi
  ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | grep -q " ${LAN_ADDR//./\\.}/" || problems+=("$LAN_ADDR is not on $LAN_IF")
  local p
  if can_root; then
    for p in udp tcp; do
      "${SUDO[@]}" iptables -C nixos-fw -i "$LAN_IF" -p $p --dport 53 -j nixos-fw-accept 2>/dev/null || problems+=("firewall does not open $p/53 on $LAN_IF")
    done
  else
    notes+=("firewall not checked (no root)")
  fi
  [ "$(systemctl is-active adguardhome.service)" = active ] || problems+=("adguardhome.service not active")
  if [ ${#problems[@]} -gt 0 ]; then emit FAIL dns "$(IFS=';'; echo "${problems[*]} ${notes[*]}")"
  elif ! have host; then emit SKIP dns "$LAN_IF has $LAN_ADDR; ${notes[*]}"
  else emit OK dns "AdGuard on $LAN_ADDR answers over UDP and TCP; $LAN_IF has $LAN_ADDR$(can_root && echo "; udp+tcp/53 open on $LAN_IF")${notes:+; ${notes[*]}}"; fi
}

# --- every proxied name answers through nginx (5xx or no answer = backend down)
check_proxy() {
  local names name code bad=() good=()
  names=$(awk -v a="$LAN_ADDR" '$1==a{for(i=2;i<=NF;i++)print $i}' /etc/hosts | sort -u)
  if [ -z "$names" ]; then emit WARN proxy "no names for $LAN_ADDR in /etc/hosts"; return; fi
  for name in $names; do
    code=$(curl -q -s -o /dev/null --max-time 10 -w '%{http_code}' --resolve "$name:443:$LAN_ADDR" "https://$name/" 2>/dev/null)
    case "$code" in 000 | 5*) bad+=("$name=$code") ;; *) good+=("${name%%.*}=$code") ;; esac
  done
  if [ ${#bad[@]} -gt 0 ]; then emit FAIL proxy "down: ${bad[*]}; ok: ${good[*]}"
  else emit OK proxy "${good[*]}"; fi
}

# --- key units from modules/services/* and the alerting timers
check_services() {
  local u s down=() missing=()
  for u in "${KEY_UNITS[@]}"; do
    if [ "$(systemctl show -p LoadState --value "$u")" != loaded ]; then missing+=("$u"); continue; fi
    s=$(systemctl is-active "$u" 2>/dev/null)
    [ "$s" = active ] || [ "$s" = activating ] || down+=("$u=$s")
  done
  if [ ${#down[@]} -gt 0 ]; then emit FAIL services "not active: ${down[*]}${missing:+; not found: ${missing[*]}}"
  elif [ ${#missing[@]} -gt 0 ]; then emit WARN services "not found (list drifted from the flake?): ${missing[*]}"
  else emit OK services "${#KEY_UNITS[@]} key units active"; fi
}

# --- Hasala: a stopped hasala.target may be the kill switch, so WARN, not FAIL
check_hasala() {
  local u s t down=() failed=()
  t=$(systemctl is-active hasala.target 2>/dev/null)
  for u in "${HASALA_UNITS[@]}"; do
    s=$(systemctl is-active "$u" 2>/dev/null)
    [ "$s" = failed ] && failed+=("$u")
    [ "$s" = active ] || [ "$s" = activating ] || down+=("$u=$s")
  done
  if [ ${#failed[@]} -gt 0 ]; then emit FAIL hasala "failed: ${failed[*]} (hasala.target $t)"
  elif [ "$t" != active ]; then emit WARN hasala "hasala.target $t, no unit failed: stopped on purpose (kill switch)?"
  elif [ ${#down[@]} -gt 0 ]; then emit FAIL hasala "hasala.target active, but not active: ${down[*]}"
  else emit OK hasala "hasala.target and ${#HASALA_UNITS[@]} units active"; fi
}

# --- Tailscale: backend running, node key expiry
check_tailscale() {
  local js state exp days
  if ! js=$(tailscale status --json --peers=false 2>/dev/null); then emit FAIL tailscale "tailscale status failed"; return; fi
  # No jq on the host: match the keys without relying on indentation.
  state=$(grep -o '"BackendState": *"[^"]*"' <<<"$js" | head -1 | cut -d'"' -f4)
  exp=$(grep -o '"KeyExpiry": *"[^"]*"' <<<"$js" | head -1 | cut -d'"' -f4)
  if [ -z "$state" ]; then emit SKIP tailscale "could not parse BackendState from tailscale status --json"; return; fi
  if [ "$state" != Running ]; then emit FAIL tailscale "BackendState=$state (remote access, subnet route, exit node and nginx-auth depend on it)"; return; fi
  if [ -z "$exp" ]; then emit OK tailscale "Running; node key expiry disabled"; return; fi
  days=$((($(date -d "$exp" +%s) - now) / 86400))
  if [ "$days" -lt 21 ]; then emit WARN tailscale "Running; node key expires in $days days ($exp)"
  else emit OK tailscale "Running; node key expires in $days days"; fi
}

# --- open PRs awaiting Saleh, and master's CI
check_prs() {
  if [ "$offline" -eq 1 ]; then emit SKIP prs "offline"; return; fi
  if ! have gh || ! gh auth status >/dev/null 2>&1; then emit SKIP prs "gh not authenticated"; return; fi
  local list ci st=OK
  # The repo is public: a PR from a fork is tagged [external] and shown by
  # number only, never its title or labels (untrusted text).
  list=$(gh pr list -R "$REPO" --state open --json number,isDraft,labels,statusCheckRollup,headRepositoryOwner \
    --jq '.[] | if .headRepositoryOwner.login != "salehtl" then "#\(.number)[external]" else "#\(.number)\(if .isDraft then "(draft)" else "" end)\([.labels[].name] | if length>0 then "["+join(",")+"]" else "" end):\([.statusCheckRollup[]? | (.conclusion // .state)] | if length==0 then "no-checks" elif all(.=="SUCCESS" or .=="NEUTRAL" or .=="SKIPPED") then "green" elif any(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED" or .=="EXPECTED" or .=="") then "pending" else "red" end)" end' 2>/dev/null) ||
    { emit SKIP prs "gh pr list failed"; return; }
  ci=$(gh run list -R "$REPO" --branch master --workflow check.yml -L 1 --json status,conclusion,headSha \
    --jq '.[0] | "\(.status)/\(.conclusion) \(.headSha[:7])"' 2>/dev/null)
  case "$ci" in completed/success*) ;; completed/*) st=FAIL ;; *) ;; esac
  # A red PR is information for Saleh, not a host fault; only red master CI alerts.
  emit "$st" prs "master CI ${ci:-unknown}; open: $(echo "$list" | grep -c '#') ${list:+($(echo "$list" | paste -sd' '))}"
}

for c in "${CHECKS[@]}"; do
  if [ -n "$only" ] && [[ ",$only," != *",$c,"* ]]; then continue; fi
  "check_$c"
done
if [ $((nok + nwarn + nfail + nskip)) -eq 0 ]; then printf 'SUMMARY\tSKIP\tno checks ran\n'; exit 64; fi

worst=OK
[ "$nwarn" -gt 0 ] && worst=WARN
[ "$nfail" -gt 0 ] && worst=FAIL
printf 'SUMMARY\t%s\tok=%d warn=%d fail=%d skip=%d\n' "$worst" "$nok" "$nwarn" "$nfail" "$nskip"
case "$worst" in OK) exit 0 ;; WARN) exit 1 ;; *) exit 2 ;; esac

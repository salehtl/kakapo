{ config, pkgs, ... }:
let
  to = "salehtl@icloud.com";
  checkScript = ../claude/skills/kakapo-health/scripts/check.sh;
  # What check.sh needs on PATH (its header lists the same).
  checkPath = [
    pkgs.bash
    pkgs.procps # before coreutils: its uptime has -s
    pkgs.coreutils
    pkgs.curl
    pkgs.bind.host
    pkgs.diffutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.iproute2
    pkgs.nvme-cli
    pkgs.smartmontools
    pkgs.util-linux
    config.networking.firewall.package
    config.nix.package
    config.services.tailscale.package
    config.systemd.package
  ];
in
{
  # Email when the 04:00 autoUpgrade fails. Nothing else watches it: a lock
  # that needed updating broke it from 2026-06-01 to 2026-10-03 — 250 failed
  # runs — and nobody knew. CI cannot catch activation-time failures either, so
  # the alert has to come from the host.
  #
  # Mail goes out through iCloud SMTP as the recipient, so no new account is
  # needed. The password is an Apple app-specific password, never the Apple ID
  # password. /etc/msmtprc is world-readable but holds only `passwordeval`; the
  # secret itself is root-only, so only root can send — which is all the
  # notifier needs.
  #
  # Outbound 587 only. Nothing here listens, so the firewall is unchanged.
  # The password is declared in modules/sops.nix.

  programs.msmtp = {
    enable = true;
    accounts.default = {
      host = "smtp.mail.me.com";
      port = 587;
      tls = true;
      tls_starttls = true;
      auth = true;
      user = to;
      from = to;
      passwordeval = "cat ${config.sops.secrets."notify/smtp_password".path}";
    };
  };

  # Template so any unit can opt in with
  # `onFailure = [ "notify-failure@%n.service" ];` — %n is the failing unit.
  systemd.services."notify-failure@" = {
    description = "Email ${to} that %i failed";
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.msmtp
      pkgs.curl
      config.systemd.package
    ];
    scriptArgs = "%i";
    script = ''
      unit="$1"
      # Phone push first (modules/services/ntfy.nix); the email below goes out
      # whether or not it worked.
      curl -fsS --max-time 10 -o /dev/null \
        -H "Title: [${config.networking.hostName}] $unit failed" -H "Priority: high" -H "Tags: warning" \
        --data-binary "$(journalctl -u "$unit" -n 10 --no-pager -o cat)" \
        http://127.0.0.1:2586/kakapo || echo "ntfy push failed" >&2
      {
        printf 'To: %s\nFrom: %s\nSubject: [%s] %s failed\n\n' \
          "${to}" "${to}" "${config.networking.hostName}" "$unit"
        systemctl status --full --no-pager "$unit" || true
        printf '\n--- last 100 journal lines ---\n'
        journalctl -u "$unit" -n 100 --no-pager -o short-iso
      } | msmtp -t
    '';
  };

  systemd.services.nixos-upgrade.onFailure = [ "notify-failure@%n.service" ];

  # Email when the running nixpkgs is more than three weeks old. The upgrade
  # alert above only fires when nixos-upgrade fails; it stays silent when the
  # upgrade succeeds but has nothing new to build — the weekly lock workflow
  # failing, or its PR sitting unmerged. Checking the age of what is actually
  # running catches every one of those. The date comes from the nixpkgs
  # version this system was built from (26.05.YYYYMMDD.rev).
  systemd.services.nixpkgs-age = {
    description = "Fail if the running nixpkgs is more than 21 days old";
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      built=$(cut -d. -f3 <<< "$(< /run/current-system/nixos-version)")
      age=$(( ($(date +%s) - $(date -d "$built" +%s)) / 86400 ))
      echo "running nixpkgs from $built, $age days old"
      if [ "$age" -gt 21 ]; then
        echo "flake.lock has not reached this host in $age days: check the update-flake-lock workflow, its open PR, and nixos-upgrade.service"
        exit 1
      fi
    '';
  };
  systemd.timers.nixpkgs-age = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "09:00";
      Persistent = true;
    };
  };

  # Email when kakapo's Tailscale node key is within three weeks of expiring.
  # It lapses 180 days after login unless key expiry is disabled for kakapo in
  # the admin console (Machines -> kakapo -> Disable key expiry), which is
  # out-of-band. At expiry tailscaled drops every peer and route: Tailscale
  # SSH, the 10.0.0.215/32 route, the exit node and tailscale-nginx-auth.
  systemd.services.tailscale-key-expiry = {
    description = "Fail if kakapo's Tailscale node key expires within 21 days";
    onFailure = [ "notify-failure@%n.service" ];
    path = [
      config.services.tailscale.package
      pkgs.jq
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      expiry=$(tailscale status --json | jq -r '.Self.KeyExpiry // empty')
      if [ -z "$expiry" ]; then
        echo "key expiry is disabled for this node"
        exit 0
      fi
      days=$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))
      echo "Tailscale node key expires $expiry, in $days days"
      if [ "$days" -lt 21 ]; then
        echo "Disable key expiry for kakapo in the Tailscale admin console: Machines -> kakapo -> Disable key expiry"
        exit 1
      fi
    '';
  };
  systemd.timers.tailscale-key-expiry = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "09:00";
      Persistent = true;
    };
  };

  # Push to ntfy when kakapo's health changes. Runs the kakapo-health skill's
  # own check (claude/skills/kakapo-health/scripts/check.sh), so what Claude
  # reports on request and what the phone is told are the same checks. It
  # runs --offline: GitHub is not polled every quarter hour, so the master,
  # PR and master-CI checks stay with the skill.
  #
  # The `generation` check is left out of alerts: it WARNs whenever a
  # guarded-test activation is live, which is routine while a PR is tested.
  #
  # Every run also pings healthchecks.io, the one alert path that does not
  # depend on kakapo: ntfy and the mail above both run here, so a dead host,
  # disk or uplink sends nothing. healthchecks.io alerts when the pings stop
  # (set the check's period to 15 min and its grace to 30 min), and on a /fail
  # ping, which a FAIL or a check that cannot run sends, so the worst states
  # also reach Saleh by a second path when ntfy itself is down.
  #
  # It pushes only when the set of WARN/FAIL lines changes, and once more when
  # everything is back to OK, so a lasting problem alerts once, not every run.
  # The unit itself succeeds on WARN/FAIL (exit 1/2), or notify-failure@ would
  # send a second alert and failed_units would flag this unit; it fails, and
  # mails, only when the check cannot run at all.
  systemd.services.health-check = {
    description = "Push kakapo health changes to ntfy";
    onFailure = [ "notify-failure@%n.service" ];
    path = checkPath;
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "health-check";
      TimeoutStartSec = "5min";
      LoadCredential = "hc_ping_url:${config.sops.secrets."healthchecks/ping_url".path}";
    };
    script = ''
      set -u
      state=/var/lib/health-check/problems
      # hc_ping [/fail] BODY: heartbeat to healthchecks.io; never fails the run.
      hc_ping() {
        curl -fsS --max-time 10 --retry 3 -o /dev/null --data-binary "$2" \
          "$(cat "$CREDENTIALS_DIRECTORY/hc_ping_url")$1" || echo "healthchecks.io ping failed" >&2
      }
      rc=0
      out=$(bash ${checkScript} --offline) || rc=$?
      printf '%s\n' "$out"
      if [ "$rc" -gt 2 ]; then
        echo "check.sh exited $rc" >&2
        hc_ping /fail "check.sh exited $rc"
        exit 1
      fi
      summary=$(printf '%s\n' "$out" | grep -Ev '^(OK|SKIP)'$'\t' | tr '\t' ' ')
      if [ "$rc" -eq 2 ]; then hc_ping /fail "$summary"; else hc_ping "" "$summary"; fi
      now=$(printf '%s\n' "$out" | grep -E '^(WARN|FAIL)'$'\t' | grep -v $'\tgeneration\t' || true)
      before=$(cat "$state" 2>/dev/null || true)
      [ "$now" = "$before" ] && exit 0
      printf '%s' "$now" >"$state"

      if [ -z "$now" ]; then
        title="[${config.networking.hostName}] health: all OK"
        prio=default tags=white_check_mark body="All checks are OK again."
      elif printf '%s\n' "$now" | grep -q '^FAIL'; then
        title="[${config.networking.hostName}] health: FAIL"
        prio=high tags=rotating_light body=$now
      else
        title="[${config.networking.hostName}] health: WARN"
        prio=default tags=warning body=$now
      fi
      curl -fsS --max-time 10 -o /dev/null \
        -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
        --data-binary "$(printf '%s\n' "$body" | tr '\t' ' ')" \
        http://127.0.0.1:2586/kakapo || {
        # Not delivered: forget the state so the next run tries again.
        rm -f "$state"
        echo "ntfy push failed" >&2
      }
    '';
  };
  systemd.timers.health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "15min";
    };
  };

  # Daily health report to ntfy at 09:00, whatever the state: one push with
  # the verdict, the facts worth a glance (upgrade, backups, disk, TLS), open
  # PRs and master CI. health-check above alerts on changes; this is the
  # "still fine" signal. It runs check.sh online, so the generation check also
  # compares with master. root has no gh login, so PRs and CI come from the
  # public GitHub API; a PR from a fork shows by number only (untrusted text).
  systemd.services.health-report = {
    description = "Daily kakapo health report to ntfy";
    onFailure = [ "notify-failure@%n.service" ];
    path = checkPath ++ [ pkgs.jq ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "10min";
    };
    script = ''
      set -u
      api=https://api.github.com/repos/salehtl/kakapo
      rc=0
      out=$(bash ${checkScript}) || rc=$?
      printf '%s\n' "$out"
      if [ "$rc" -gt 2 ]; then
        echo "check.sh exited $rc" >&2
        exit 1
      fi
      summary=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "SUMMARY" { print $2 " (" $3 ")" }')
      problems=$(printf '%s\n' "$out" | grep -E '^(WARN|FAIL)'$'\t' | cut -f2- | tr '\t' ' ' || true)
      facts=$(printf '%s\n' "$out" | awk -F'\t' '$2 ~ /^(upgrade|backups|disk|tls|nixpkgs_age)$/ { print $2 ": " $3 }')
      prs=$(curl -fsS --max-time 15 "$api/pulls?state=open&per_page=30" | jq -r '.[] |
        if .head.repo.owner.login != "salehtl" then "#\(.number) [external]"
        else "#\(.number) \(.title)" end') || prs="(GitHub API failed)"
      ci=$(curl -fsS --max-time 15 "$api/commits/master/status" |
        jq -r '(if .total_count == 0 then "none" else .state end) + " " + .sha[:7]') || ci="(GitHub API failed)"

      case "$rc" in
        0) prio=low tags=white_check_mark ;;
        1) prio=default tags=warning ;;
        *) prio=high tags=rotating_light ;;
      esac
      body=$(
        [ -n "$problems" ] && printf 'Needs attention:\n%s\n\n' "$problems"
        printf '%s\n\n' "$facts"
        printf 'master CI: %s\n' "$ci"
        printf 'Open PRs: %s\n' "''${prs:-none}"
      )
      curl -fsS --max-time 10 -o /dev/null \
        -H "Title: [${config.networking.hostName}] daily: $summary" -H "Priority: $prio" -H "Tags: $tags" \
        --data-binary "$body" \
        http://127.0.0.1:2586/kakapo
    '';
  };
  systemd.timers.health-report = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "09:00";
      Persistent = true;
    };
  };
}

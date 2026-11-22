{ config, pkgs, ... }:
let
  to = "salehtl@icloud.com";
  # Every host alert goes through this (pkgs/kakapo-alert: format, levels,
  # channels). dns-health builds the same package.
  alert = pkgs.callPackage ../pkgs/kakapo-alert {
    inherit (config.networking) hostName;
    mailTo = to;
  };
  alertExe = "${alert}/bin/kakapo-alert";
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
  # kakapo's alerts. One fault gives one alert, and every alert goes through
  # kakapo-alert (pkgs/kakapo-alert): title "[kakapo] LEVEL SOURCE: SUBJECT",
  # ntfy topic `kakapo`, and mail only for `fail` (and its recovery).
  #
  # | Source               | Alerts on                                  | Level     |
  # |----------------------|--------------------------------------------|-----------|
  # | notify-failure@      | a unit with onFailure fails (nixos-upgrade,| fail      |
  # |                      | spoof check, Hasala, backup, the alerters) |           |
  # | dns-health (adguard) | DNS down 2 min in a row; recovery          | fail / ok |
  # | health-check         | any other check enters/leaves WARN or FAIL | warn/fail/ok |
  # | health-report        | daily 09:00 status, held bump PRs          | info/warn |
  # | healthchecks.io      | kakapo stops reporting (outside kakapo)    | its own   |
  #
  # Hasala's own notices (hasala-health findings, early-access requests)
  # come from its module in github:salehtl/hasala, in its own format.
  #
  # Mail goes out through iCloud SMTP as the recipient, so no new account is
  # needed. The password is an Apple app-specific password, never the Apple ID
  # password. /etc/msmtprc is world-readable but holds only `passwordeval`; the
  # secret itself is root-only (modules/sops.nix), so only root can send.
  # Outbound 587 only. Nothing here listens, so the firewall is unchanged.

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

  # notify-failure@<unit>: the alert for a failed unit. Any unit opts in with
  # `onFailure = [ "notify-failure@%n.service" ];` (%n is the failing unit).
  # The push shows the last log lines; the mail adds the status and the last
  # 100 journal lines.
  systemd.services."notify-failure@" = {
    description = "Alert Saleh that %i failed";
    serviceConfig.Type = "oneshot";
    path = [ config.systemd.package ];
    scriptArgs = "%i";
    script = ''
      unit="$1"
      desc=$(systemctl show -p Description --value "$unit" 2>/dev/null || true)
      {
        printf 'Last log lines:\n'
        journalctl -u "$unit" -n 10 --no-pager -o cat
        printf '\n--- status ---\n'
        systemctl status --full --no-pager "$unit" || true
        printf '\n--- last 100 journal lines ---\n'
        journalctl -u "$unit" -n 100 --no-pager -o short-iso
      } | ${alertExe} fail "''${unit%.service}" "failed''${desc:+ ($desc)}"
    '';
  };

  systemd.services.nixos-upgrade.onFailure = [ "notify-failure@%n.service" ];

  # health-check: every 15 minutes, the kakapo-health skill's own check
  # (claude/skills/kakapo-health/scripts/check.sh --offline), so what Claude
  # reports on request and what the phone is told are the same checks.
  #
  # One alert per change: it alerts when a check enters WARN or FAIL, changes
  # between them, or all checks are OK again. It compares status and check
  # name only, not the detail text, which carries live numbers.
  #
  # It leaves out what another alert already sends, so one fault gives one
  # alert:
  #   - dns: dns-health (modules/services/adguard.nix) alerts within 2 minutes;
  #   - generation: WARNs during every guarded test, which is routine;
  #   - failed_units, upgrade "last result", hasala "failed:": a unit with
  #     notify-failure@ has already alerted for itself.
  # The daily health-report still lists everything.
  #
  # Every run also pings healthchecks.io, the one alert path that does not
  # depend on kakapo: ntfy and the mail both run here, so a dead host, disk or
  # uplink sends nothing. healthchecks.io alerts when the pings stop (period
  # 15 min, grace 30 min), and on a /fail ping, which a FAIL or a check that
  # cannot run sends, with the full check output.
  #
  # The unit succeeds on WARN/FAIL (check.sh exit 1/2); it fails, and so
  # alerts through notify-failure@, only when the check cannot run at all.
  systemd.services.health-check = {
    description = "kakapo health checks, alert on change";
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

      # The WARN/FAIL lines that no other alert covers (see above).
      covered() { systemctl show -p OnFailure --value "$1" 2>/dev/null | grep -q 'notify-failure@'; }
      now=$(printf '%s\n' "$out" | while IFS=$'\t' read -r st name detail; do
        case "$st" in WARN | FAIL) ;; *) continue ;; esac
        case "$name" in
          dns | generation) continue ;;
          upgrade) [[ $detail == "last nixos-upgrade result="* ]] && continue ;;
          hasala) [[ $detail == "failed: "* ]] && continue ;;
          failed_units)
            left=
            for u in $detail; do covered "$u" || left="$left $u"; done
            [ -z "$left" ] && continue
            detail="''${left# }" ;;
        esac
        printf '%s\t%s\t%s\n' "$st" "$name" "$detail"
      done)
      # Status and name; failed_units also by its unit list, which has no
      # live numbers.
      key=$(printf '%s\n' "$now" | awk -F'\t' 'NF { print $1 "\t" $2 ($2 == "failed_units" ? "\t" $3 : "") }')
      before=$(cat "$state" 2>/dev/null || true)
      [ "$key" = "$before" ] && exit 0

      body=$(printf '%s\n' "$now" | awk -F'\t' 'NF { print $1 " " $2 ": " $3 }')
      names=$(printf '%s\n' "$now" | awk -F'\t' 'NF { print $2 }' | paste -sd, - | sed 's/,/, /g')
      if [ -z "$now" ]; then
        # Mail the recovery only when the problem was mailed (a FAIL).
        alert=(ok health "all checks OK")
        printf '%s\n' "$before" | grep -q '^FAIL' && alert+=(--mail)
        body="All checks are OK again."
      elif printf '%s\n' "$now" | grep -q '^FAIL'; then
        alert=(fail health "$names")
      else
        alert=(warn health "$names")
      fi
      if printf '%s\n' "$body" | ${alertExe} "''${alert[@]}"; then
        printf '%s' "$key" >"$state"
      else
        echo "alert not delivered; the next run tries again" >&2
      fi
    '';
  };
  systemd.timers.health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "15min";
    };
  };

  # health-report: the daily status at 09:00, whatever the state: the
  # verdict, every WARN/FAIL (also the ones health-check leaves to other
  # alerts), the facts worth a glance, open PRs and master CI. It runs
  # check.sh online, so the generation check also compares with master.
  #
  # It also names a bump PR that did not merge itself (update-flake-lock.yml
  # holds it with `needs-review`), so nixpkgs or Claude Code does not drift.
  # Level `info` when nothing needs Saleh, else `warn`; never mailed.
  #
  # root has no gh login, so PRs and CI come from the public GitHub API. A PR
  # from a fork shows by number only, and a bump PR counts only from this
  # repo's own branch (PR titles and fork branch names are untrusted).
  systemd.services.health-report = {
    description = "Daily kakapo health report";
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
      verdict=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "SUMMARY" { print $2 }')
      problems=$(printf '%s\n' "$out" | grep -E '^(WARN|FAIL)'$'\t' | cut -f1- | tr '\t' ' ' | sed 's/ /: /2' || true)
      facts=$(printf '%s\n' "$out" | awk -F'\t' '$2 ~ /^(upgrade|backups|disk|tls|nixpkgs_age)$/ { print $2 ": " $3 }')
      held=
      if pulls=$(curl -fsS --max-time 15 "$api/pulls?state=open&per_page=30"); then
        prs=$(printf '%s' "$pulls" | jq -r '.[] |
          if .head.repo.full_name != "salehtl/kakapo" then "#\(.number) [external]"
          else "#\(.number) \(.title)" end')
        held=$(printf '%s' "$pulls" | jq -r --argjson now "$(date +%s)" '.[]
          | select(.head.repo.full_name == "salehtl/kakapo" and (.head.ref == "flake-lock-bump" or .head.ref == "app-bump"))
          | (($now - (.created_at | fromdateiso8601)) / 86400 | floor) as $d
          | select($d >= 1)
          | "bump PR #\(.number) (\(.head.ref)) did not merge itself; open \($d) day(s). Review it (kakapo-update), then merge it."')
      else
        prs="(GitHub API failed)"
      fi
      ci=$(curl -fsS --max-time 15 "$api/commits/master/status" |
        jq -r '(if .total_count == 0 then "none" else .state end) + " " + .sha[:7]') || ci="(GitHub API failed)"

      level=info
      { [ -n "$problems" ] || [ -n "$held" ]; } && level=warn
      body=$(
        if [ -n "$problems$held" ]; then
          printf 'Needs attention:\n'
          [ -n "$problems" ] && printf '%s\n' "$problems"
          [ -n "$held" ] && printf '%s\n' "$held"
          printf '\n'
        fi
        printf '%s\n\n' "$facts"
        printf 'master CI: %s\n' "$ci"
        printf 'Open PRs: %s\n' "''${prs:-none}"
      )
      printf '%s\n' "$body" | ${alertExe} "$level" report "daily: $verdict" --click https://github.com/salehtl/kakapo/pulls
    '';
  };
  systemd.timers.health-report = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "09:00";
      Persistent = true;
    };
  };

  # For agents and Saleh, to send an alert by hand (root only: the mail
  # password is root-only).
  environment.systemPackages = [ alert ];
}

{ config, pkgs, ... }:
let
  to = "salehtl@icloud.com";
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
}

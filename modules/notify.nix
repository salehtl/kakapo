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
      config.systemd.package
    ];
    scriptArgs = "%i";
    script = ''
      unit="$1"
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
}

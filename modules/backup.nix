{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.kakapo.backup;
  # Consistent copies of the live SQLite databases go here first; restic then
  # backs up this directory instead of the files the services are writing.
  staging = "/var/backups/restic-staging";
in
{
  # Off-site, encrypted restic backup of the data that exists nowhere else.
  #
  # Today every copy of it lives on this host: the Immich library and its
  # nightly database dumps, and Hasala's age-encrypted dumps, are all on the
  # one media SSD (/mnt/media, sda); ledger and Gramps Web are on the root
  # NVMe. One failed disk, a fire or a theft loses them. Everything else on
  # kakapo is declared in this flake and rebuilds from it.
  #
  # Off until a target is chosen (Backblaze B2, a Hetzner Storage Box, a NAS,
  # an external disk, ...). To turn it on:
  #   1. Add secrets/backup.yaml with `backup/restic_password` (a new random
  #      password; keep a copy outside kakapo, or the backup cannot be read)
  #      and `backup/env` (the target's credentials as KEY=value lines, e.g.
  #      B2_ACCOUNT_ID / B2_ACCOUNT_KEY; may be empty for a local disk).
  #   2. Set kakapo.backup.enable = true and kakapo.backup.repository.
  #   3. After the first run, restore a file to check it (restic-kakapo is the
  #      wrapper: `sudo restic-kakapo snapshots`, `... restore latest --target`).
  #
  # Left out on purpose: live PostgreSQL data dirs (the Immich and Hasala dumps
  # cover them), regenerable Immich thumbnails and transcodes, metrics, Docker
  # images, and the SSH host key. sops secrets are also encrypted to Saleh's
  # Mac key (.sops.yaml), so they can be recovered without the host key.
  options.kakapo.backup = {
    enable = lib.mkEnableOption "the off-site restic backup";
    repository = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "b2:kakapo-backup:/restic";
      description = "restic repository URL of the backup target.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.repository != null;
        message = "kakapo.backup.enable needs kakapo.backup.repository.";
      }
    ];

    sops.secrets = {
      "backup/restic_password".sopsFile = ../secrets/backup.yaml;
      "backup/env".sopsFile = ../secrets/backup.yaml;
    };

    services.restic.backups.kakapo = {
      inherit (cfg) repository;
      initialize = true;
      passwordFile = config.sops.secrets."backup/restic_password".path;
      environmentFile = config.sops.secrets."backup/env".path;
      paths = [
        "/mnt/media/immich/library"
        "/mnt/media/immich/upload"
        "/mnt/media/immich/profile"
        "/mnt/media/immich/backups"
        "/mnt/media/hasala-backup"
        "/var/lib/ledger/backups"
        "/var/lib/grampsweb/media"
        "/var/lib/grampsweb/secret"
        staging
      ];
      backupPrepareCommand = ''
        set -eu
        install -d -m 0700 ${staging}
        for db in /var/lib/ledger/ledger.db \
                  /var/lib/grampsweb/users/users.sqlite \
                  /var/lib/grampsweb/grampsdb/*/*.db; do
          dest=${staging}/$(echo "''${db#/var/lib/}" | tr / _)
          ${lib.getExe pkgs.sqlite} "$db" ".backup '$dest'"
        done
      '';
      backupCleanupCommand = "rm -rf ${staging}";
      # After Immich's and Hasala's nightly dumps (02:00, 03:15) and the
      # 04:00 upgrade.
      timerConfig = {
        OnCalendar = "05:00";
        Persistent = true;
        RandomizedDelaySec = "15min";
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-monthly 12"
      ];
      runCheck = true;
      checkOpts = [ "--read-data-subset=2%" ];
    };

    systemd.services.restic-backups-kakapo = {
      onFailure = [ "notify-failure@%n.service" ];
      # Immich and its dumps live on the media SSD; never back up an empty
      # mount point.
      unitConfig.RequiresMountsFor = [ "/mnt/media" ];
    };
  };
}

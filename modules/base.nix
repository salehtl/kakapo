{
  config,
  lib,
  pkgs,
  ...
}:
{
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      trusted-users = [
        "root"
        "@wheel"
      ];
    };
    # No --delete-older-than: it has no floor, so a month with no rebuilds would
    # leave one generation and no rollback target. prune-system-generations
    # below applies the age rule with a minimum count, right before this
    # collection.
    gc = {
      automatic = true;
      dates = "weekly";
    };
  };

  time.timeZone = "Asia/Dubai";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    tmux
    vim
    wget
    tree
    fd
    ripgrep
    lsof
    pciutils
    usbutils
    smartmontools
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      # keyboard-interactive is a second password path, through PAM. Off, so
      # SSH stays key-only even if an account ever gets a password.
      KbdInteractiveAuthentication = false;
      # Nothing here needs unix-socket forwarding (ssh -L/-R to a socket path),
      # which the Tailworm report abuses.
      AllowStreamLocalForwarding = "no";
    };
  };

  services.tailscale = {
    enable = true;
    # 26.05 stays on 1.98.x; unstable tracks upstream releases, which carry
    # tailscaled's security fixes.
    package = pkgs.unstable.tailscale;
    # Tailscale SSH is off: sshd above answers port 22 on the tailnet too,
    # with the YubiKey sk- keys and no root login. Tailscale SSH authenticates
    # the device, not the user, and runs as root (the Tailworm report,
    # tailworm.com). The tailnet policy has no `ssh` section either.
    # `tailscale set` keeps a flag it is not given, so turning it off must be
    # explicit; an assertion in hosts/kakapo/default.nix checks it.
    extraSetFlags = [
      "--ssh=false"
      # Always explicit, for the same reason: without the flag an earlier exit
      # node stays advertised. The exit node exists for
      # modules/services/zapret.nix. Given once only: `tailscale set` rejects
      # a repeated flag.
      "--advertise-exit-node=${lib.boolToString config.services.zapret.enable}"
      # Keep kakapo's own resolv.conf (networking.nameservers): its lookups
      # must not depend on tailscaled or loop through its own AdGuard. The
      # quad-100 resolver keeps serving *.ts.net to AdGuard regardless.
      "--accept-dns=false"
    ];
  };

  # tailscaled runs as root and normally uses under 100M. Capped, so a peer or
  # DERP relay that makes it grow without bound (Tailworm findings 5 and 6)
  # gets it OOM-killed and restarted instead of taking the host's memory.
  systemd.services.tailscaled.serviceConfig.MemoryMax = "1G";

  # Leftovers of modules/services/zapret.nix after it is removed: a firewall
  # reload runs only the new generation's commands, so the mangle jump into
  # its chain, and IPv6 forwarding, would stay until reboot. zapret.nix
  # re-adds the jump after this, and its forwarding setting outranks this.
  networking.firewall.extraCommands = lib.mkBefore ''
    iptables -t mangle -D POSTROUTING -j kakapo-zapret 2>/dev/null || true
    ip6tables -t mangle -D POSTROUTING -j kakapo-zapret 2>/dev/null || true
  '';
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkDefault false;

  networking.firewall.enable = true;

  # What the unit runs is replaced in modules/guarded-upgrade.nix: master is
  # activated through scripts/guarded-test.sh and becomes the boot default
  # only if the house's DNS, the firewall and the units survived it.
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:00";
    flake = "github:salehtl/kakapo#${config.networking.hostName}";
    flags = [ "-L" ];
    # Persistent (the module default) stays: a missed 04:00 runs at the next
    # boot. The upgrade takes the guarded-test lock, so it cannot switch the
    # host under a running test.
  };

  # Age-based generation pruning with a floor: the newest `keep` are excluded
  # before the age filter.
  systemd.services.prune-system-generations =
    let
      keep = 4;
      retainDays = 30;
    in
    {
      description = "Prune system generations older than ${toString retainDays}d, keeping the newest ${toString keep}";
      before = [ "nix-gc.service" ];
      wantedBy = [ "nix-gc.service" ];
      serviceConfig.Type = "oneshot";
      path = [
        config.nix.package
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnused
      ];
      script = ''
        set -eu
        profile=/nix/var/nix/profiles/system
        cutoff=$(date -d "${toString retainDays} days ago" +%s)
        current=$(basename "$(readlink "$profile")" | sed 's/^system-\([0-9]*\)-link$/\1/')

        # Generation numbers newest-first, skipping the newest ${toString keep}.
        # The current generation is normally inside that window; the explicit
        # skip below guards the case where the profile has been rolled back.
        candidates=$(nix-env -p "$profile" --list-generations \
          | awk '{ print $1 }' | sort -rn | tail -n +${toString (keep + 1)})

        doomed=""
        for g in $candidates; do
          if [ "$g" = "$current" ]; then continue; fi
          stamp=$(nix-env -p "$profile" --list-generations \
            | awk -v g="$g" '$1 == g { print $2 " " $3 }')
          if [ -z "$stamp" ]; then continue; fi
          if [ "$(date -d "$stamp" +%s)" -lt "$cutoff" ]; then
            doomed="$doomed $g"
          fi
        done

        if [ -n "$doomed" ]; then
          echo "pruning generations:$doomed"
          nix-env -p "$profile" --delete-generations $doomed
        else
          echo "nothing to prune: no generation older than ${toString retainDays}d outside the newest ${toString keep}"
        fi
      '';
    };
}

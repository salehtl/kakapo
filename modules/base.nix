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
    # No --delete-older-than here on purpose: that flag deletes generations with
    # no floor, so a month with no rebuilds would leave exactly one generation
    # and destroy every rollback target. prune-system-generations below applies
    # the same age rule while never dropping below a minimum count, and runs
    # immediately before this collection so the freed paths go in the same pass.
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
    };
  };

  services.tailscale = {
    enable = true;
    # Tailscale SSH serves port 22 on the tailnet interface. Authentication is
    # tailnet identity plus the tailnet SSH policy, not authorized_keys.
    #
    # sshd above stays enabled on purpose. It still serves the LAN, which is the
    # recovery path when Tailscale or its control plane is unavailable, and
    # humaid's node (anoa) is not a principal in the tailnet SSH policy, so
    # Tailscale SSH alone would lock him out.
    extraSetFlags = [
      "--ssh"
      # Always explicit: `tailscale set` only changes the flags it is given,
      # so a generation without the flag kept an earlier exit node advertised
      # (and approved) with nothing declaring it. The exit node exists for
      # modules/services/zapret.nix. Given once only: `tailscale set` rejects
      # a repeated flag.
      "--advertise-exit-node=${lib.boolToString config.services.zapret.enable}"
      # Keep kakapo's own resolv.conf (networking.nameservers). Tailscale DNS,
      # on by default, had put 100.100.100.100 there: kakapo's lookups then
      # depended on tailscaled, and a tailnet DNS server pointed at AdGuard
      # would have looped them through kakapo itself. The quad-100 resolver
      # keeps serving *.ts.net to AdGuard regardless.
      "--accept-dns=false"
    ];
  };

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

  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:00";
    flake = "github:salehtl/kakapo#${config.networking.hostName}";
    flags = [ "-L" ];
    # Persistent (the module default) stays: a missed 04:00 runs at the next
    # boot. Turning it off (2026-10-07) did not stop nixos-upgrade firing
    # mid-activation, since the timer was already running and Persistent=
    # only matters when a timer starts, and it froze the timer's stamp, so
    # booting an older generation would have upgraded it straight back.
    # The misfire is unexplained; scripts/guarded-test.sh exits 3 when it
    # switches the host under a test.
  };

  # Age-based generation pruning with a floor. `nix-collect-garbage
  # --delete-older-than` cannot express "but always keep N", and deletion is
  # not reversible, so the floor is applied by exclusion before the age filter
  # rather than after it.
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

{ config, pkgs, ... }:
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
    extraSetFlags = [ "--ssh" ];
  };

  networking.firewall.enable = true;

  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:00";
    flake = "github:salehtl/kakapo#${config.networking.hostName}";
    flags = [ "-L" ];
    # The module defaults to Persistent=true, a catch-up run for a missed
    # 04:00. On kakapo it fired mid-activation instead: on 2026-10-06 (after a
    # clock jump) and on 2026-10-07 at 13:48 although 04:00 had already run,
    # both times switching the host to master under a branch being tested.
    # A missed night now waits for the next one.
    persistent = false;
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

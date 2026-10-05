{ config, ... }:
let
  host = config.networking.hostName;
in
{
  # Managed-policy CLAUDE.md: loaded by every Claude Code / agent session on this
  # host regardless of user or working directory, and not excludable by user
  # settings. A session that starts outside /etc/nixos would otherwise see none
  # of this. Keep it an orientation pointer, not a copy of the repo's CLAUDE.md —
  # duplicating that file here would let the two drift apart.
  environment.etc."claude-code/CLAUDE.md".text = ''
    # ${host} — host operating context

    You are on **${host}**, a single-host NixOS server. Everything about this
    machine is declared in one flake: **github:salehtl/kakapo**.

    ## Read this before changing anything

    The authoritative guide is that repo's own `CLAUDE.md`:

        /etc/nixos/CLAUDE.md

    `/etc/nixos` is a plain git checkout kept for reference. **It can be stale.**
    Confirm it before trusting a word of it:

        sudo git -C /etc/nixos fetch origin && sudo git -C /etc/nixos status -sb

    If it is behind, fast-forward it (`sudo git -C /etc/nixos merge --ff-only
    origin/master`) or read the repo from GitHub instead. This has already caused
    one near-miss: the checkout sat at the repo's first commit while the host ran
    master, and rebuilding from it would have rolled ${host} back — dropping
    monitoring, ledger, sops secrets and the NVIDIA driver, and downgrading
    nixpkgs by a release.

    ## How changes actually deploy

    `system.autoUpgrade` runs `nixos-rebuild switch` against
    `github:salehtl/kakapo#${host}` **daily at 04:00**. Whatever is on `master`
    then is what this host runs. CI is advisory and will not block a bad push.

    - Editing files on the host deploys nothing. Changes land by pushing `master`.
    - `nixos-rebuild test` activates without becoming default: it reverts on
      reboot and is overwritten at 04:00. Use it to verify, never to finish.
      Installing something this way looks like success and silently vanishes.
    - `nixos-rebuild switch` persists across reboot, but `master` still replaces
      it at 04:00.
    - Verify a branch before merging:

          sudo nixos-rebuild test --flake github:salehtl/kakapo/<branch>#${host} --refresh

    - Pushing to `master` is a deploy. Treat it as one.
    - autoUpgrade only builds what `flake.lock` pins. It never moves the lock,
      so nixpkgs stays frozen until someone runs `nix flake update` and pushes.
    - It can fail every night with nothing to show for it. A `flake.lock` that
      needed updating broke it from 2026-06-01 to 2026-10-03 — 250 failed runs,
      no alert. Before assuming this host is current, check:

          systemctl status nixos-upgrade.service
          journalctl -u nixos-upgrade.service --since -7d

    ## Invariants — do not work around these

    - `users.mutableUsers = false`. Never `useradd`, `passwd`, or edit `/etc/passwd`.
    - SSH is key-only. Never enable password auth or root login.
    - Services bind `127.0.0.1`. They reach the tailnet via `tailscale serve`,
      or the whole LAN via the `*.home.salehtl.com` nginx proxy in
      `modules/services/home-domain.nix` — never by opening a new port.
    - Open ports: 22 everywhere; 53 (AdGuard) on the LAN and tailnet; 443
      (the home-domain proxy) on the LAN and tailnet. All interface-scoped except 22,
      and guarded by assertions. Nothing else.
    - Port 22 is open on **every** interface on purpose: it is the LAN fallback
      for when Tailscale is unavailable. Do not narrow it to `tailscale0`.
    - Secrets are sops-encrypted under `secrets/`. Never commit plaintext.
    - The `assertions` in `hosts/${host}/default.nix` are guardrails, not ceremony.
    - Run `nix fmt` before committing; CI fails on unformatted Nix.

    ## Confirming what is really running

        readlink /run/current-system
        sudo nixos-rebuild list-generations | tail -5
        nix store diff-closures /run/booted-system /run/current-system

    A reboot is needed only when the kernel or initrd changes — compare
    `/run/booted-system/kernel` against `/run/current-system/kernel`. Activating
    a new generation does not require one.
  '';
}

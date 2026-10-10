{ config, lib, ... }:
let
  host = config.networking.hostName;
  normalUsers = lib.filter (u: u.isNormalUser) (lib.attrValues config.users.users);
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

    ## Working on a project, not the host?

    Projects live in `~/src/<name>`, and their rules are in
    `/etc/claude-code/projects.md`. It loads automatically for any session
    under `~/src` (it is linked there as `~/src/CLAUDE.md`). **Before cloning
    or creating a project, or working on one from anywhere else, read it.** In
    short: tools come from the project's own flake, never the host; no sudo;
    bind `127.0.0.1`; never touch the host or the kakapo flake from project
    work.

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
    then is what this host runs.

    **Every change is a pull request; nobody pushes to `master`.** Several
    agents may be working on this flake and this host at once. A GitHub
    ruleset blocks direct pushes to `master` and requires the `check` and
    `build` CI jobs to pass and the branch to be up to date before a merge.
    **Never merge a PR yourself** (`gh pr merge`, the API, or by editing the
    ruleset), even though your credentials would allow it: merging is a deploy,
    and it is Saleh's call. The full workflow, including resolving conflicts,
    is "Making a change" in `/etc/nixos/CLAUDE.md`. In short:

    1. Clone the repo into your own scratchpad (never work in `/etc/nixos`)
       and branch off `origin/master`.
    2. Change, `nix fmt`, build the toplevel.
    3. Test with `scripts/guarded-test.sh <built system>`, never a bare
       `nixos-rebuild test`/`switch`. It locks the host so only one agent's
       activation runs at a time.
    4. Push the branch, `gh pr create --base master`, give Saleh the link,
       and stop there.
    5. If `master` moves first, rebase, re-test and force-push your own branch.

    - Editing files on the host deploys nothing. Changes land when Saleh
      merges a PR into `master`.
    - A test activation (what `guarded-test.sh` does) does not become the
      default: it reverts on reboot and is overwritten at 04:00. Use it to
      verify, never to finish. Installing something this way looks like
      success and silently vanishes.
    - `nixos-rebuild switch` persists across reboot, but `master` still replaces
      it at 04:00. Do not use it to ship a change; open a PR.
    - Merging into `master` is a deploy. Treat it as one.
    - autoUpgrade only builds what `flake.lock` pins. It never moves the lock,
      so nixpkgs stays frozen until a `flake.lock` bump PR is merged (a
      workflow opens one every Monday).
    - It can fail every night with nothing to show for it. A `flake.lock` that
      needed updating broke it from 2026-06-01 to 2026-10-03 — 250 failed runs,
      no alert. Before assuming this host is current, check:

          systemctl status nixos-upgrade.service
          journalctl -u nixos-upgrade.service --since -7d

    ## Invariants — do not work around these

    - `users.mutableUsers = false`. Never `useradd`, `passwd`, or edit `/etc/passwd`.
    - SSH is key-only. Never enable password auth or root login.
    - Services bind `127.0.0.1` and are reached only through the
      `<service>.salehtl.com` nginx proxy in `modules/services/lan-proxy.nix`
      (`proxied` for the house, `tailnetOnly` for tailnet devices). Nothing
      uses `tailscale serve`; its config is cleared at every boot. Never open a
      new port.
    - Open ports: 22 everywhere; 53 (AdGuard) on the LAN and tailnet; 443
      (the LAN proxy) on the LAN and tailnet. All interface-scoped except 22,
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

  # Rules for project work, as opposed to host work. Claude Code loads every
  # CLAUDE.md from the working directory up, so linking the guide as
  # ~/src/CLAUDE.md reaches every session started in a project there,
  # including T3 Code's agents, without loading it into host sessions.
  environment.etc."claude-code/projects.md".source = ./claude-projects.md;
  systemd.tmpfiles.rules = lib.concatMap (u: [
    "d ${u.home}/src 0755 ${u.name} ${u.group} -"
    "L+ ${u.home}/src/CLAUDE.md - - - - /etc/claude-code/projects.md"
  ]) normalUsers;
}

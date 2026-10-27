{
  description = "kakapo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Claude Code, herdr (not in 26.05), and Immich with its NixOS module.
    # The 26.05 release branch does not backport Claude Code: it sat on 2.1.223
    # while upstream shipped 2.1.287, and a `nix flake update` moved the
    # whole release forward three days without moving this package at all. The
    # tool releases several times a week, so tracking it on the release branch
    # means running months-old builds.
    #
    # Deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"` — the point is a
    # second, newer package set, exposed as `pkgs.unstable`. Used for those
    # three only (and the Immich module swap below); nothing else on this
    # host comes from unstable.
    # `nixpkgs-unstable` rather than `master` because it is the channel Hydra
    # has actually built.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ledger = {
      url = "github:salehtl/ledger";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Hasala's QA backend (modules/services/hasala.nix), for its NixOS module.
    # Pinned to a commit, not a branch: `nix flake update` cannot move a rev,
    # so the weekly lock bump never deploys unreleased hasala work. Releasing
    # to QA is a PR that changes this rev to a CI-green commit of hasala main:
    # .github/workflows/hasala-release.yml opens one every hour when there is
    # a new one, and it auto-merges unless it changes a migration or the module.
    # (hasala's infra/qa/HOST-PR.md suggests a release branch such as `qa`;
    # none exists yet, and once one does it can replace the rev.)
    # Deliberately NO `follows`: the host runs exactly the closure hasala's CI
    # built and tested (its own nixos-26.05 lock, Go 1.27 from nixos-unstable).
    hasala.url = "github:salehtl/hasala/85e631782b56a23bbbed3d75c2ca8a421f1a9f9d";
    # nook: the reading-room planner and the GPU trainer for nook-scan iPhone
    # room scans (modules/services/nook.nix), for its NixOS module. Pinned to a
    # commit like hasala, so the weekly lock bump never deploys unreleased nook
    # work; release by changing the rev. Follows our nixpkgs: nook pins nothing
    # of its own, and sharing the host's keeps the closure small.
    nook = {
      url = "github:salehtl/nook/46bd511c1831435bb711ecef35c0d83b92881be0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      treefmt-nix,
      sops-nix,
      ledger,
      hasala,
      nook,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      # Exposed to every module as `pkgs.unstable` (overlay below), so a package
      # taken from unstable is named as such where it is used:
      # `pkgs.unstable.claude-code`, never a silent override of `pkgs.<name>`.
      #
      # A separate import rather than `nixpkgs-unstable.legacyPackages` because
      # claude-code is unfree, and `nixpkgs.config.allowUnfreePredicate` in
      # hosts/kakapo only governs the host's own package set; a second package
      # set carries its own config. The predicate is deliberately just the
      # unfree packages this host takes from unstable, not a copy of the
      # host's list.
      unstableFor =
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-code";
          overlays = [
            # claude-code's launcher prepends alsa-lib (audio) to
            # LD_LIBRARY_PATH, and every command an agent runs inherits it:
            # programs from other nixpkgs revisions then load that libasound
            # and fail on a glibc mismatch (Chromium did, 2026-10-07). kakapo is
            # headless with no audio, so give it an empty directory instead.
            (final: prev: {
              claude-code = prev.claude-code.override { alsa-lib = final.emptyDirectory; };
            })
          ];
        };
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      treefmtFor = system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix;
    in
    {
      nixosConfigurations.kakapo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/kakapo
          sops-nix.nixosModules.sops
          ledger.nixosModules.default
          hasala.nixosModules.default
          nook.nixosModules.default
          {
            # Immich 3 with the module written for it. 26.05 ships Immich 2.7.5,
            # marked insecure (two CVEs, 2.x is unmaintained); Immich 3 lands in
            # 26.11. Drop this, and pkgs.unstable.immich in
            # modules/services/immich.nix, once on 26.11.
            disabledModules = [ "services/web-apps/immich.nix" ];
            imports = [ "${nixpkgs-unstable}/nixos/modules/services/web-apps/immich.nix" ];
          }
          {
            nixpkgs.overlays = [
              (final: _prev: {
                unstable = unstableFor final.stdenv.hostPlatform.system;
              })
            ];
          }
        ];
      };

      formatter = forAllSystems (system: (treefmtFor system).config.build.wrapper);

      checks = forAllSystems (system: {
        formatting = (treefmtFor system).config.build.check self;
      });
    };
}

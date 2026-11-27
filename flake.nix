{
  description = "kakapo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # A second, newer package set, exposed as `pkgs.unstable`, for what 26.05
    # lacks or does not keep current (Claude Code, Immich 3 and its module,
    # ...). Deliberately NOT `inputs.nixpkgs.follows`. `nixpkgs-unstable`
    # rather than `master`: it is the channel Hydra has built.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Hasala's QA backend (modules/services/hasala.nix), for its NixOS module.
    # Pinned to a commit, not a branch: `nix flake update` cannot move a rev,
    # so the weekly lock bump never deploys unreleased hasala work. A release
    # is a PR that changes this rev (.github/workflows/hasala-release.yml).
    # Deliberately NO `follows`: the host runs exactly the closure hasala's CI
    # built and tested.
    hasala.url = "github:Hasala/hasala/f549e194baa55aefa71b0986c8aa84f46f9c93b4";
    # midstudy (modules/services/midstudy.nix), for its NixOS module. Pinned to
    # a commit like hasala. Deliberately NO `follows`: its CUDA torch comes
    # from its own pinned nixpkgs, so a nixpkgs bump here never rebuilds the
    # CUDA libraries (hours).
    midstudy.url = "github:salehtl/midstudy/96470c30213a9a075aaf11ad6581bd97012b4967";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      treefmt-nix,
      sops-nix,
      hasala,
      midstudy,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      # `pkgs.unstable` (overlay below): a package from unstable is named as
      # such where it is used, never a silent override of `pkgs.<name>`.
      # A separate import because claude-code is unfree and a second package
      # set carries its own config. The predicate lists only the unfree
      # packages this host takes from unstable.
      unstableFor =
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-code";
          overlays = [
            # claude-code's launcher prepends alsa-lib to LD_LIBRARY_PATH, and
            # every command an agent runs inherits it: programs from other
            # nixpkgs revisions then load that libasound and fail on a glibc
            # mismatch. kakapo has no audio, so give it an empty directory.
            #
            # The version is ours, not nixpkgs-unstable's:
            # pkgs/claude-code/manifest.json is Anthropic's release manifest for
            # the version kakapo runs, and scripts/bump-apps.sh moves it daily
            # (update-flake-lock.yml, `apps` run).
            (final: prev: {
              claude-code = prev.claude-code.override {
                alsa-lib = final.emptyDirectory;
                manifest = builtins.fromJSON (builtins.readFile ./pkgs/claude-code/manifest.json);
              };
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
          hasala.nixosModules.default
          midstudy.nixosModules.default
          {
            # Immich 3 with the module written for it: 26.05 ships the insecure,
            # unmaintained 2.7.5. Drop this, and pkgs.unstable.immich in
            # modules/services/immich.nix, once on 26.11.
            disabledModules = [ "services/web-apps/immich.nix" ];
            imports = [ "${nixpkgs-unstable}/nixos/modules/services/web-apps/immich.nix" ];
          }
          {
            # CLIProxyAPI's module is not in 26.05 (modules/services/cliproxyapi.nix).
            # Its `meta.doc` is dropped: 26.05's manual has no redirects for the
            # doc's anchors, and the manual build fails on them. Drop this
            # block once on 26.11.
            imports =
              let
                path = "${nixpkgs-unstable}/nixos/modules/services/misc/cliproxyapi.nix";
                module = import path;
              in
              [
                {
                  _file = path;
                  imports = [
                    (nixpkgs.lib.setFunctionArgs (args: removeAttrs (module args) [ "meta" ]) (
                      nixpkgs.lib.functionArgs module
                    ))
                  ];
                }
              ];
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

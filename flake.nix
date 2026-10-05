{
  description = "kakapo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Claude Code only. The 26.05 release branch does not backport it: it sat on
    # 2.1.223 while upstream shipped 2.1.287, and a `nix flake update` moved the
    # whole release forward three days without moving this package at all. The
    # tool releases several times a week, so tracking it on the release branch
    # means running months-old builds.
    #
    # Deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"` — the point is a
    # second, newer package set. Scope is one package, via the overlay below;
    # nothing else on this host comes from unstable. `nixpkgs-unstable` rather
    # than `master` because it is the channel Hydra has actually built.
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
    herdr = {
      url = "github:herdrdev/herdr/v0.9.3";
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
      herdr,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      # claude-code is unfree, and `nixpkgs.config.allowUnfreePredicate` in
      # hosts/kakapo only governs *this* host's package set — a second package
      # set carries its own config, so the predicate does not reach it and
      # evaluation fails with "has an unfree license". Hence a separate import
      # rather than `nixpkgs-unstable.legacyPackages`. The predicate here is
      # deliberately one name, not a copy of the host's list: this package set
      # exists to produce exactly one package.
      unstableFor =
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-code";
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
          {
            nixpkgs.overlays = [
              (_final: _prev: {
                herdr = herdr.packages.x86_64-linux.default;
                inherit (unstableFor "x86_64-linux") claude-code;
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

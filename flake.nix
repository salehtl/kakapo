{
  description = "kakapo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      sops-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      treefmtFor = system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix;
    in
    {
      nixosConfigurations.kakapo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/kakapo
          sops-nix.nixosModules.sops
        ];
      };

      formatter = forAllSystems (system: (treefmtFor system).config.build.wrapper);

      checks = forAllSystems (system: {
        formatting = (treefmtFor system).config.build.check self;
      });
    };
}

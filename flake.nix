{
  description = "kakapo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
  };

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.kakapo = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/kakapo
      ];
    };
  };
}

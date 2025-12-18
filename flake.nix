{
  description = "nix config";

  inputs = {
    # Nixpkgs
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # Home manager
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    # Secret encryption
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    # Hardware
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    # Impermanence
    impermanence.url = "github:nix-community/impermanence";
    # Disko
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    # nix index for comma
    nix-index-database.url = "github:Mic92/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      ...
    }@inputs:
    {
      nixosConfigurations =
        let
          mkSystem =
            path:
            nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              specialArgs = { inherit inputs; };
              modules = [ path ];
            };
          # host machines
          hostConfigs = nixpkgs.lib.genAttrs (builtins.attrNames (builtins.readDir ./hosts/nixos)) (
            name: mkSystem ./hosts/nixos/${name}
          );
        in
        hostConfigs;

      overlays = import ./modules/overlays { inherit inputs; };

      nixosModules = {
        nebulis = import ./modules/hosts/nixos.nix;
      };

      homeManagerModules = {
        nebulis = import ./modules/home-manager;
      };

      users = {
        nebulis = import ./users;
      };
    };
}

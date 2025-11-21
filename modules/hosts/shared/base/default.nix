{
  config,
  lib,
  inputs,
  pkgs,
  ...
}:
let
  cfg = config.nebulis.shared.base;
in
{
  options.nebulis.shared.base = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''basic configuration that should be set for all host systems by default'';
    };
  };

  config = lib.mkIf cfg.enable {
    nebulis = {
      fish.enable = true;
      agenix.enable = true;
      nixSettings.enable = true;
      network.basics = true;
    };
    nixpkgs.overlays = [ ];
    environment.systemPackages = with pkgs; [
      vim
      git
      agenix
      nixos-rebuild
    ];
  };
}

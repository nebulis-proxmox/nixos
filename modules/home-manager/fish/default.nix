{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nebulis.fish;
in
{
  options.nebulis.fish = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable custom fish module
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs = {
      fish.enable = true;
      starship.enable = true;
    };
  };
}

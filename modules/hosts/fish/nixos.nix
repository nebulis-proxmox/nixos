{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nebulis.fish;
in
{
  config = lib.mkIf cfg.enable {
    programs.fish.enable = true;
    environment.shells = with pkgs; [ fish ];
  };
}
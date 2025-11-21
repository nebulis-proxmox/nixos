{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nebulis.shared.basic;
in
{
  imports = [ ];
  options.nebulis.shared.basic = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable custom suite
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    nebulis = {
      # comma.enable = true;
      # bash.enable = true;
      # tmux.enable = true;
      # fish.enable = true;
      # direnv.enable = true;
      # spotlight-links.enable = true;
    };
  };
}

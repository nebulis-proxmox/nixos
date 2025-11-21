{
  lib,
  ...
}:
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
}
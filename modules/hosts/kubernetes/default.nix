{
  lib,
  ...
}:
{
  options.nebulis.kubernetes = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable kubernetes host module
      '';
    };
  };
}

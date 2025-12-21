{
  lib,
  ...
}:
{
  options.nebulis.crio = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable cri-o host module
      '';
    };
  };
}

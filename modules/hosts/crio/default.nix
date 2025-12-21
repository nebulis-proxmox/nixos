{
  lib,
  ...
}:
{
  options.nebulis.crio = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        enable cri-o host module
      '';
    };
  };
}

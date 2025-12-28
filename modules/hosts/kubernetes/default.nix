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
    kind = lib.mkOption {
      type = lib.types.enum [
        "control-plane"
        "worker"
      ];
      default = "control-plane";
      description = ''
        kind of kubernetes node
      '';
    };
    mode = lib.mkOption {
      type = lib.types.enum [
        "lan"
        "tailscale"
      ];
      default = "lan";
      description = ''
        networking mode for kubernetes cluster communication
      '';
    };
  };
}

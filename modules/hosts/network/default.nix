{
  lib,
  ...
}:
{
  options.nebulis.network = {
    basics = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable custom nix settings
      '';
    };
    physicalInterfaceName = lib.mkOption {
      type = lib.types.str or lib.types.null;
      default = null;
      description = ''
        physical interface name - used for useBr0 option below
      '';
    };
    useBr0 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        use a bridge, for nixos containers / vms
      '';
    };
    useTailscaleForSSH = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use tailscale for SSH connection
      '';
    };
  };
}

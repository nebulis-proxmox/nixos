{
  lib,
  inputs,
  ...
}:
{
  imports = [
    # import custom modules
    inputs.self.nixosModules.nebulis
  ];
  config = {
    networking.hostName = "hetzner-nu1-nwmqpa";
    system.stateVersion = "25.11";

    nebulis = {
      autoUpgrade.enable = true;

      shared.base = {
        enable = true;
      };

      kubernetes = {
        enable = true;
        mode = "tailscale";
        nodeIndex = 0;
        kind = [
          "control-plane"
          "worker"
        ];
      };

      tailscale = {
        enable = true;
        useRoutingFeatures = "both";
        extraUpFlags = [ ];
      };

      network = {
        useBr0 = true;
        physicalInterfaceName = "enp1s0";
      };

      timezone.paris = true;

      # disk configuration
      disks = {
        enable = true;
        systemd-boot = true;

        zfs = {
          enable = true;
          hostID = "a153c64f";
          root = {
            poolName = "rpool";
            encrypt = false;
            disk1 = "sda";
            reservation = "20G";
            impermanenceRoot = true;
          };
          storage = {
            enable = false;
          };
        };
      };
    };
  };
}

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
    networking.hostName = "utm-nwmqpa";
    system.stateVersion = "25.11";

    nebulis = {
      autoUpgrade.enable = true;

      shared.base = {
        enable = true;
        consoleKeyMap = "mac-fr";
      };

      kubernetes = {
        enable = true;
        mode = "tailscale";
        nodeIndex = 0;
      };

      tailscale = {
        enable = true;
        useRoutingFeatures = "both";
        extraUpFlags = [ ];
      };

      network = {
        useBr0 = true;
        physicalInterfaceName = "enp0s1";
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
            disk1 = "nvme0n1";
            reservation = "5G";
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

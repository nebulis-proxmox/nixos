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
    networking.hostName = "dedicated";
    system.stateVersion = "25.05";

    nebulis = {
      suites.foundation.enable = true;
      network = {
        useBr0 = true;
        physicalInterfaceName = "enp1s0";
      };
      # disk configuration
      disks = {
        enable = true;
        systemd-boot = true;
        zfs = {
          enable = true;
          hostID = "a153c64f";
          root = {
            disk1 = "nvme0n1";
            impermanenceRoot = true;
          };
        };
      };
    };
  };
}

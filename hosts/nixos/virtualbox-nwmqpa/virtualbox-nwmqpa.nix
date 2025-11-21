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
    networking.hostName = "virtualbox-nwmqpa";
    system.stateVersion = "25.05";

    nebulis = {
      shared.base.enable = true;

      network = {
        useBr0 = true;
        physicalInterfaceName = "enp0s3";
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

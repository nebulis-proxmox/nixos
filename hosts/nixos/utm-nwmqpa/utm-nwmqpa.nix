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
    system.stateVersion = "26.05";

    nebulis = {
      autoUpgrade.enable = true;

      shared.base = {
        enable = true;
      };

      network = {
        useBr0 = false;
        physicalInterfaceName = "enp1s0";
      };

      disks = {
        enable = true;
        systemd-boot = true;

        brtfs = {
          enable = true;

          storage = {
            enable = true;

            disks = {
              vda = {
                boot.enable = true;
                swap = {
                  enable = true;
                  size = "2G";
                };
              };
            };
          };
        };
      };
    };
  };
}

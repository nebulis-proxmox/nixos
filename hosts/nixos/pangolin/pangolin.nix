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
    networking.hostName = "pangolin";
    system.stateVersion = "26.05";

    nebulis = {
      autoUpgrade.enable = true;

      network = {
        useBr0 = false;
        physicalInterfaceName = "enp1s0";
      };

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
            reservation = "30G";
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

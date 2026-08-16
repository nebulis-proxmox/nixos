{
  lib,
  inputs,
  config,
  ...
}:
let
  inherit (config.nebulis.impermanence) dontBackup;
in
{
  imports = [
    # import custom modules
    inputs.self.nixosModules.nebulis
  ];
  config = {
    networking.hostName = "pangolin";
    system.stateVersion = "26.05";

    services.pangolin = {
      enable = true;
      dataDir = "/var/lib/pangolin";
      baseDomain = "nebulis.dev";
      letsEncryptEmail = "thomas.nicollet@nebulis.io";
    };

    environment.persistence."${dontBackup}".directories = [ services.pangolin.dataDir ];

    nebulis = {
      autoUpgrade.enable = true;

      shared.base = {
        enable = true;
      };

      network = {
        useBr0 = false;
        physicalInterfaceName = "eth0";
      };

      disks = {
        enable = true;
        systemd-boot = true;

        brtfs = {
          enable = true;

          storage = {
            enable = true;

            disks = {
              sda = {
                boot.enable = true;
                swap = {
                  enable = true;
                  size = "8G";
                };
              };
            };
          };
        };
      };
    };
  };
}

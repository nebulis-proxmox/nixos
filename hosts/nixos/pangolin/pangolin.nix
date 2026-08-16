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
      environmentFile = "/etc/nixos/secrets/pangolin.env";
    };

    age.secrets = {
      "pangolin.env".file = inputs.self + "/secrets/pangolin.env.age";
    };

    environment.etc = {
      "nixos/secrets/pangolin.env" = {
        source = config.age.secrets."pangolin.env".path;
        mode = "0600";
      };
    };

    environment.persistence."${dontBackup}".directories = [ config.services.pangolin.dataDir ];

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

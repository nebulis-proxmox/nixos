{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nebulis.disks;
  inherit (config.networking) hostName;
  inherit (config.nebulis.impermanence) dontBackup;
in
{
  options.nebulis.disks = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable custom disk configuration
      '';
    };
    isReinstalling = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        am I reinstalling and want to save the storage pool + keep /persist/save unused so I can restore data
      '';
    };
    systemd-boot = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.systemd-boot) {
      # setup systemd-boot
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
    })
    (lib.mkIf cfg.enable {
      # basic impermanence folders setup
      environment.persistence."${dontBackup}" = {
        hideMounts = true;
        directories = [
          "/var/lib/bluetooth"
          "/var/lib/nixos"
          "/var/lib/systemd/coredump"
          "/etc/NetworkManager/system-connections"
        ];
      };
    })
  ];
}

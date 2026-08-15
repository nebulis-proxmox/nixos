{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nebulis.disks;
  setToList = set: (map (key: builtins.getAttr key set) (builtins.attrNames set));
  inherit (config.networking) hostName;
  inherit (config.nebulis.impermanence) dontBackup;
in
{
  options.nebulis.disks.brtfs = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };

    storage = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      disks = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              boot = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    enable = lib.mkOption {
                      type = lib.types.bool;
                      default = false;
                    };
                  };
                };
              };

              swap = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    enable = lib.mkOption {
                      type = lib.types.bool;
                      default = false;
                    };

                    size = lib.mkOption {
                      type = lib.types.str;
                      default = "";
                    };
                  };
                };
              };
            };
          }
        );
      };
      default = { };
      description = "Disks Config";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.brtfs.enable {
      disko.devices = {
        disk = lib.mkMerge [
          (lib.mkIf (cfg.brtfs.storage.enable && !cfg.isReinstalling) (
            lib.mkMerge (
              setToList (
                builtins.mapAttrs (name: disk: {
                  "${name}" = {
                    type = "disk";
                    device = "/dev/${name}";
                    content = {
                      type = "gpt";
                      partitions = {
                        esp = lib.mkIf disk.boot.enable {
                          priority = 1;
                          name = "ESP";
                          start = "1M";
                          end = "128M";
                          type = "EF00";
                          content = {
                            type = "filesystem";
                            format = "vfat";
                            mountpoint = "/boot";
                            mountOptions = [ "umask=0077" ];
                          };
                        };

                        swap = lib.mkIf disk.swap.enable {
                          priority = 2;
                          size = disk.swap.size;
                          content = {
                            type = "swap";
                            discardPolicy = "both";
                            resumeDevice = true;
                          };
                        };

                        main = {
                          size = "100%";
                          content = {
                            type = "btrfs";
                            extraArgs = [ "-f" ];
                            subvolumes = {
                              "/root" = {
                                mountOptions = [
                                  "compress=zstd"
                                  "noatime"
                                ];
                                mountpoint = "/";
                              };
                              # Subvolume name is the same as the mountpoint
                              "/home" = {
                                mountOptions = [
                                  "compress=zstd"
                                  "noatime"
                                ];
                                mountpoint = "/home";
                              };
                              "/nix" = {
                                mountOptions = [
                                  "compress=zstd"
                                  "noatime"
                                ];
                                mountpoint = "/nix";
                              };
                              "/persist" = {
                                mountOptions = [
                                  "compress=zstd"
                                  "noatime"
                                ];
                                mountpoint = "/persist";
                              };
                              "/persist/save" = {
                                mountOptions = [
                                  "compress=zstd"
                                  "noatime"
                                ];
                                mountpoint = "/persist/save";
                              };
                              "/var/log" = {
                                mountOptions = [
                                  "compress=zstd"
                                  "noatime"
                                ];
                                mountpoint = "/var/log";
                              };
                              "/etc/ssh" = {
                                mountOptions = [
                                  "compress=zstd"
                                  "noatime"
                                ];
                                mountpoint = "/etc/ssh";
                              };
                            };
                          };
                        };
                      };
                    };
                  };
                }) cfg.brtfs.storage.disks
              )
            )
          ))
        ];
      };

      # Needed for agenix.
      # nixos-anywhere currently has issues with impermanence so agenix keys are lost during the install process.
      # as such we give /etc/ssh its own brtfs subvolume rather than using impermanence to save the keys when we wipe the root directory on boot
      # agenix needs the keys available before the brtfs volumes are mounted, so we need this to make sure they are available.
      fileSystems."/etc/ssh".neededForBoot = true;
      # Needed for impermanence, because we mount /persist/save on /persist, we need to make sure /persist is mounted before /persist/save
      fileSystems."/persist".neededForBoot = true;
      fileSystems."/persist/save".neededForBoot = true;
      fileSystems."/var/log".neededForBoot = true;
      fileSystems."/home".neededForBoot = true;

      boot.initrd = {
        enable = true;
        supportedFilesystems = [ "btrfs" ];
      };
    })
  ];
}

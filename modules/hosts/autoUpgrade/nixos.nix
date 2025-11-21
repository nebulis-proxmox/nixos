{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
# base around https://github.com/Misterio77/nix-config/blob/main/hosts/common/global/auto-upgrade.nix

let
  cfg = config.nebulis.autoUpgrade;
  # Only enable auto upgrade if current config came from a clean tree
  # This avoids accidental auto-upgrades when working locally.
  inherit (config.networking) hostName;
  isClean = inputs.self ? rev;
in
{
  options.nebulis.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable custom autoUpgrade module
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      system.autoUpgrade = {
        enable = isClean;
        dates = "hourly";
        flags = [ "--refresh" ];
        flake = "github:nebulis-proxmox/nixos";
      };

      # Only run if current config (self) is older than the new one.
      systemd.services.nixos-upgrade = lib.mkIf config.system.autoUpgrade.enable {
        serviceConfig.ExecCondition = lib.getExe (
          pkgs.writeShellScriptBin "check-date" ''
            lastModified() {
              nix flake metadata "$1" --refresh --json | ${lib.getExe pkgs.jq} '.lastModified'
            }
            test "$(lastModified "${config.system.autoUpgrade.flake}")"  -gt "$(lastModified "self")"
          ''
        );
      };
    })
  ];
}

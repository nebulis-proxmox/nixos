{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nebulis.ssh;
  hostsCfg = config.inventory.hosts;
  # Generate host entries
  regularHostEntries = lib.mapAttrs (hostname: hostConfig: {
    hostNames = [ hostname ];
    publicKey = hostConfig.publicKey.host;
  }) (lib.filterAttrs (hostname: hostConfig: hostConfig.publicKey.host != "") hostsCfg);
  # Merge
  allHostEntries = regularHostEntries;
in
{
  options = {
    nebulis.ssh = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          enable custom ssh module
        '';
      };
    };
    inventory.hosts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.publicKey = {
            host = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                host pubkey
              '';
            };
          };
        }
      );
    };
  };
  config = lib.mkIf cfg.enable {
    programs.ssh.knownHosts = allHostEntries;
    services.openssh = {
      enable = true;
    };
  };
}
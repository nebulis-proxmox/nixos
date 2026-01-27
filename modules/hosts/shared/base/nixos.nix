{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.nebulis.shared.base;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      console.keyMap = cfg.consoleKeyMap;

      nebulis = {
        autoUpgrade.enable = true;
        fwupd.enable = true;
        # monitorServices.enable = true;
        ssh.enable = true;
      };
      inventory.hosts."${config.networking.hostName}" = {
        # glances.enable = true;
      };

      environment.enableAllTerminfo = true;
    })
    {
      assertions = lib.mkIf cfg.enable [
        {
          assertion = cfg.enable -> lib.hasAttr config.networking.hostName config.inventory.hosts;
          message = "Error: Hostname '${config.networking.hostName}' not found in inventory.";
        }
        {
          assertion =
            let
              inventoryHosts = builtins.attrNames config.inventory.hosts;
              nixosHosts = builtins.attrNames inputs.self.nixosConfigurations;
              invalidHosts = lib.subtractLists nixosHosts inventoryHosts;
            in
            invalidHosts == [ ];
          message = "Error: The following hosts in inventory don't exist in nixosConfigurations: ${
            lib.concatStringsSep ", " (
              let
                inventoryHosts = builtins.attrNames config.inventory.hosts;
                nixosHosts = builtins.attrNames inputs.self.nixosConfigurations;
                invalidHosts = lib.subtractLists nixosHosts inventoryHosts;
              in
              invalidHosts
            )
          }";
        }
      ];
    }
  ];
}

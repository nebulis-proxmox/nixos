{
  config,
  lib,
  ...
}:
let
  cfg = config.nebulis.network;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.basics {
      networking.networkmanager.enable = false;

      networking.firewall = {
        enable = true;
        allowedTCPPorts = lib.mkForce [ ];
        allowedUDPPorts = lib.mkForce [ (lib.mkIf config.nebulis.tailscale.enable 41641) ];
        allowPing = true;
      };

      # The notion of "online" is a broken concept
      # https://github.com/systemd/systemd/blob/e1b45a756f71deac8c1aa9a008bd0dab47f64777/NEWS#L13
      systemd.services.NetworkManager-wait-online.enable = false;
      systemd.network.wait-online.enable = false;

    })
    (lib.mkIf cfg.useBr0 {
      networking.bridges = {
        br0 = {
          interfaces = [ cfg.physicalInterfaceName ];
        };
      };

      networking.useDHCP = lib.mkForce false;
      networking.interfaces.br0.useDHCP = true;
      networking.interfaces."${cfg.physicalInterfaceName}".useDHCP = true;
    })
    (lib.mkIf (!cfg.useBr0) {
      networking.useDHCP = lib.mkForce true;
    })
    (lib.mkIf (!cfg.useTailscaleForSSH) {
      networking.firewall.allowedTCPPorts = lib.mkForce [ 22 ];
    })
  ];
}

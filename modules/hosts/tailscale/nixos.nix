{
  options,
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

with lib;
let
  cfg = config.nebulis.tailscale;
  inherit (config.networking) hostName;
in
{
  config = mkMerge [
    (lib.mkIf cfg.enable {
      services.tailscale = {
        enable = true;
        package = pkgs.unstable.tailscale;
        authKeyFile = cfg.authKeyFile;
        extraUpFlags = [
          (lib.mkIf cfg.enableSsh "--ssh=true")
          (lib.mkIf cfg.acceptDns "--accept-dns=true")
          (lib.mkIf cfg.resetCredentials "--reset=true")
          (
            "--advertise-tags="
            + (concatStringsSep "," (map (tag: "tag:" + tag) (cfg.tags ++ [ "nixos-managed" ])))
          )
        ]
        ++ cfg.extraUpFlags;
        useRoutingFeatures = cfg.useRoutingFeatures;
        permitCertUid = "caddy";
      };

      environment.persistence."${config.nebulis.impermanence.dontBackup}" = {
        hideMounts = true;
        directories = [
          "/var/lib/tailscale"
        ];
      };
      nebulis.tailscale.tailnetName = "nebulis.io";
      age.secrets.tailscaleKey.file = (inputs.self + /secrets/tailscaleKey.age);
    })
    (lib.mkIf cfg.preApprovedSshAuthkey {
      age.secrets.tailscaleKeyAcceptSsh.file = (inputs.self + /secrets/tailscaleKeyAcceptSsh.age);
    })
  ];
}

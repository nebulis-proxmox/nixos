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
        package = cfg.package;
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

      systemd = {
        targets = {
          tailscale-svcs = {
            wantedBy = [ "multi-user.target" ];
          };
        };

        services = lib.mapAttrs' (
          name: value:
          nameValuePair ("tailscale-${name}-svc") ({
            enableStrictShellChecks = true;
            path = [
              cfg.package
              pkgs.util-linux
            ];
            after = [
              "tailscaled.service"
              "tailscaled-autoconnect.service"
            ];
            requires = [ "tailscaled.service" ] ++ value.requires;

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };

            script = ''
              (
                flock -w 10 9 || exit 1
                tailscale serve --service=svc:${name} --${value.mode}=${toString value.port} ${value.target}
              ) 9>/var/lock/tailscale-svcs.lock
            '';
            preStop = "(tailscale serve drain svc:${name} && sleep 10) || true";
            postStop = ''
              (
                flock -w 10 9 || exit 1
                tailscale serve clear svc:${name} || true
              ) 9>/var/lock/tailscale-svcs.lock
            '';

            wantedBy = [ "tailscale-svcs.target" ];
          })
        ) cfg.services;
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

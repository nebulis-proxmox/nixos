{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nebulis.kubernetes;
  tailscaleCfg = config.nebulis.tailscale;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
        kubernetes
      ];

      nebulis.tailscale.tags = [
        "kubernetes-control-plane"
      ];

      systemd.services.tailscale-k8s-svc = {
        enableStrictShellChecks = true;
        path = [
          tailscaleCfg.package
        ];
        after = [
          "tailscaled.service"
          "tailscaled-autoconnect.service"
        ];
        requires = [ "tailscaled.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = "tailscale serve --service=svc:k8s --tcp=443 127.0.0.1:8080";
        preStop = "tailscale serve drain svc:k8s && sleep 10";
        postStop = "tailscale serve clear svc:k8s";

        wantedBy = [ "multi-user.target" ];
      };
    })
  ];
}

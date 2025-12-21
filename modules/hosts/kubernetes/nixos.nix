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
        cri-o
      ];

      systemd.services.crio = {
        path = [
          pkgs.cri-o
        ];

        wantedBy = [ "multi-user.target" ];
        aliases = [ "cri-o.service" ];

        description = "Container Runtime Interface for OCI (CRI-O)";
        documentation = [ "https://github.com/cri-o/cri-o" ];
        wants = [ "network-online.target" ];
        before = [ "kubelet.service" ];
        after = [ "network-online.target" ];

        serviceConfig = {
          Type = "notify";
          EnvironmentFile = "-/etc/sysconfig/crio";
          Environment = "GOTRACEBACK=crash";
          TasksMax = "infinity";
          LimitNPROC = 1048576;
          OOMScoreAdjust = -999;
          TimeoutStartSec = 0;
          Restart = "on-failure";
          RestartSec = 10;
          WatchdogSec = "60s";
          ExecStart = ''
            ${pkgs.cri-o}/bin/crio \
              $CRIO_CONFIG_OPTIONS \
              $CRIO_RUNTIME_OPTIONS \
              $CRIO_STORAGE_OPTIONS \
              $CRIO_NETWORK_OPTIONS \
              $CRIO_METRICS_OPTIONS
          '';
          ExecReload = ''
            kill -HUP $MAINPID
          '';
        };
      };

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

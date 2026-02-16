{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nebulis.crio;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
        cri-o
        cri-tools
        cni
        calicoctl # Enable only with K8S ?
      ];

      environment.etc = {
        "containers/policy.json" = {
          text = ''
            {
              "default": [
                {
                  "type": "insecureAcceptAnything"
                }
              ],
              "transports": {
                "docker-daemon": {
                  "": [
                    {
                      "type": "insecureAcceptAnything"
                    }
                  ]
                }
              }
            }
          '';
          mode = "0644";
        };
        "containers/registries/00-unqualified-search-registries.conf" = {
          text = ''
            unqualified-search-registries = ["docker.io"]
          '';
          mode = "0644";
        };
        "containers/registries/01-k8s-search-registries.conf" = {
          text = ''
            [[registry]]
            prefix = "registry.k8s.io"
            location = "registry.k8s.io"
            insecure = false
          '';
          mode = "0644";
        };
        "cni/net.d/10-calico.conflist" = {
          text = ''
            {
              "name": "k8s-pod-network",
              "cniVersion": "1.0.0",
              "plugins": [
                {
                  "type": "calico",
                  "log_level": "info",
                  "datastore_type": "kubernetes",
                  "mtu": 1500,
                  "ipam": {
                    "type": "calico-ipam"
                  },
                  "policy": {
                    "type": "k8s"
                  },
                  "kubernetes": {
                    "kubeconfig": "/etc/kubernetes/calico-cni.conf"
                  }
                },
                {
                  "type": "portmap",
                  "snat": true,
                  "capabilities": {"portMappings": true}
                }
              ]
            }
          '';
          mode = "0644";
        };
        "crictl.yaml" = {
          text = ''
            runtime-endpoint: unix:///var/run/crio/crio.sock
          '';
          mode = "0644";
        };
      };

      systemd.services.crio =
        let
          calico-cni-plugin-ipam = pkgs.calico-cni-plugin.overrideAttrs (
            final: prev: {
              pname = prev.pname + "-ipam";
              installPhase = ''
                ${prev.installPhase}
                mv $out/bin/calico $out/bin/calico-ipam
              '';
            }
          );
        in
        {
          path = [
            pkgs.cri-o
            pkgs.mount
            pkgs.coreutils
            pkgs.cni-plugins
            pkgs.calico-cni-plugin
            calico-cni-plugin-ipam
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
                --cni-plugin-dir=${lib.getBin pkgs.cni-plugins}/bin \
                --cni-plugin-dir=${lib.getBin pkgs.calico-cni-plugin}/bin \
                --cni-plugin-dir=${lib.getBin calico-cni-plugin-ipam}/bin \
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
    })
  ];
}

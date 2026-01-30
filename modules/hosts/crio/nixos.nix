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
        cni-plugins
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
        "cni/net.d/10-crio-bridge.conflist" = {
          text = ''
            {
              "cniVersion": "1.0.0",
              "name": "crio",
              "plugins": [
                {
                  "type": "bridge",
                  "bridge": "cni0",
                  "isGateway": true,
                  "ipMasq": true,
                  "hairpinMode": true,
                  "ipam": {
                    "type": "host-local",
                    "routes": [
                        { "dst": "0.0.0.0/0" },
                        { "dst": "::/0" }
                    ],
                    "ranges": [
                        [{ "subnet": "10.96.0.0/16" }]
                    ]
                  }
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

      systemd.services.crio = {
        path = [
          pkgs.cri-o
          pkgs.mount
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

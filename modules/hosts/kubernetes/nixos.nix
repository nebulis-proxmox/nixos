{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  cfg = config.nebulis.kubernetes;
  neworkingCfg = config.nebulis.network;
  tailscaleCfg = config.nebulis.tailscale;

  thenOrNull = condition: value: if condition then value else null;

  indent =
    n: str:
    lib.strings.concatStringsSep ("\n" + (lib.concatStrings (lib.replicate n "\t"))) (
      lib.strings.splitString "\n" str
    );

  ipCommand =
    if cfg.mode == "tailscale" then
      "$(tailscale ip -4)"
    else
      # Ensure no IPv6 addresses are returned nor the loopback address
      "$(ip -json -br a | jq '[.[] | .addr_info[] | select(.prefixlen > 32 | not) | select(.local != \"127.0.0.1\") | .local][0]' -r)";

  tailscaleDnsCommand = thenOrNull (
    cfg.mode == "tailscale"
  ) "$(tailscale dns status | grep -A1 'suffix' | awk '{print $6}' | sed -e 's/)//g')";

  clusterHost =
    if cfg.mode == "tailscale" then
      "${cfg.tailscaleApiServerSvc}.${tailscaleDnsCommand}"
    else
      "${cfg.apiServerHost}";

  clusterAddr =
    "${clusterHost}:" + (if cfg.mode == "tailscale" then "443" else toString cfg.apiServerPort);

  etcdClusterHost =
    if cfg.mode == "tailscale" then
      "${cfg.tailscaleEtcdSvc}.${tailscaleDnsCommand}"
    else
      "${cfg.apiServerHost}";

  etcdClusterAddr =
    "${etcdClusterHost}:" + (if cfg.mode == "tailscale" then "443" else toString cfg.etcdPeerPort);

  pathPackages =
    if cfg.mode == "tailscale" then
      [
        tailscaleCfg.package
        pkgs.iptables
        pkgs.socat
      ]
    else
      [
        pkgs.jq
      ];

  afterUnits =
    if cfg.mode == "tailscale" then
      [ "tailscaled.service" ]
    else
      (if neworkingCfg.useBr0 then [ "network-addresses-br0.service" ] else [ ]);

  waitForNetwork = ''
    until [ ! -z "${ipCommand}" ] && [ "${ipCommand}" != "null" ]; do
      echo "Waiting for valid IP address..."
      sleep 1
    done
  '';

  waitForDns = thenOrNull (cfg.mode == "tailscale") ''
    until [ ! -z "${tailscaleDnsCommand}" ] && [ "${tailscaleDnsCommand}" != "search" ]; do
      echo "Waiting for Tailscale DNS suffix..."
      sleep 1
    done
  '';

  readModuleFile = file: builtins.readFile "${inputs.self}/modules/hosts/kubernetes/${file}";

  mkCertFunction = readModuleFile "scripts/mkCert.sh";

  mkCert =
    {
      ca,
      cert,
      subject,
      expirationDays,
      altNames ? { },
    }:
    let
      subjectString = lib.strings.concatStrings (
        lib.attrsets.mapAttrsToList (k: v: "/${k}=${v}") subject
      );
      subjectArg = if subjectString == "" then "" else "-subj '${subjectString}'";

      altNamesLine = builtins.concatStringsSep ", " (
        lib.attrsets.mapAttrsToList (
          kind: values:
          builtins.concatStringsSep ", " (map (v: "${kind}:${v}") (lib.lists.filter (v: v != null) values))
        ) altNames
      );

      altNamesExt = if altNamesLine == "" then "" else "subjectAltName = ${altNamesLine}";
      altNamesExtArg = if altNamesExt == "" then "" else "-addext \"${altNamesExt}\"";
      altNamesExtFileArg = if altNamesExt == "" then "" else "-extfile <(echo \"${altNamesExt}\")";
    in
    "mkCert \"${ca}\" \"${cert}\" \"${toString expirationDays}\" \"${subjectString}\" \"${altNamesExt}\"";

  mkKubeconfigFunction =
    builtins.replaceStrings
      [ "$NIX_MK_CERT_WITH_GROUP" "$NIX_MK_CERT" ]
      [
        (mkCert {
          ca = "$ca";
          cert = "$kubeconfig";
          subject = {
            CN = "$username";
            O = "$group";
          };
          expirationDays = "$expirationDays";
        })
        (mkCert {
          ca = "$ca";
          cert = "$kubeconfig";
          subject = {
            CN = "$username";
          };
          expirationDays = "$expirationDays";
        })
      ]
      (readModuleFile "scripts/mkKubeconfig.sh");

  mkKubeconfig =
    {
      ca,
      kubeconfig,
      username,
      group ? "",
      expirationDays,
      isLocal ? false,
    }:
    let
      shadowedClusterAddr = if isLocal then "$ipAddr:${toString cfg.apiServerPort}" else "$clusterAddr";
    in
    "mkKubeconfig \"${ca}\" \"${kubeconfig}\" \"${shadowedClusterAddr}\" \"${toString expirationDays}\" \"${username}\" \"${group}\"";

  mkTempSuperAdminKubeconfig =
    (mkKubeconfig {
      ca = "/etc/kubernetes/pki/ca";
      kubeconfig = "/etc/kubernetes/temp.conf";
      username = "kubernetes-super-admin";
      group = "system:masters";
      expirationDays = 1;
      isLocal = false;
    })
    + "\ntrap 'rm -f /etc/kubernetes/temp.conf' EXIT";

  clusterTestCommand = "curl --silent --fail --insecure \"https://${clusterAddr}/readyz\" --max-time 10 >/dev/null";

  adminKubectl = "kubectl --kubeconfig=/etc/kubernetes/admin.conf";
  adminTempKubectl = "kubectl --kubeconfig=/etc/kubernetes/temp.conf";

  isControlPlane = builtins.elem "control-plane" cfg.kind;
  isWorker = builtins.elem "worker" cfg.kind;
  isOnlyControlNode = isControlPlane && !isWorker;
  isOnlyWorkerNode = isWorker && !isControlPlane;
  isControlAndWorker = isControlPlane && isWorker;

  toBooleanString = b: if b then "true" else "false";

  restartTailscaleSvc = thenOrNull (
    cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)
  ) "systemctl restart tailscale-${cfg.tailscaleApiServerSvc}-svc.service || true";
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [
        pkgs.unstable.kubernetes
        pkgs.openssl
      ];

      age.secrets = {
        "ca-kubernetes.key".file = inputs.self + "/secrets/ca-kubernetes.key.age";
        "ca-etcd.key".file = inputs.self + "/secrets/ca-etcd.key.age";
        "ca-kubernetes-front-proxy.key".file = inputs.self + "/secrets/ca-kubernetes-front-proxy.key.age";
        "sa-kubernetes.key".file = inputs.self + "/secrets/sa-kubernetes.key.age";
      };

      environment.etc = {
        "kubernetes/pki/ca.key" = {
          source = config.age.secrets."ca-kubernetes.key".path;
          mode = "0600";
        };
        "kubernetes/pki/ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-kubernetes.crt";
          mode = "0644";
        };
        "kubernetes/pki/front-proxy-ca.key" = {
          source = config.age.secrets."ca-kubernetes-front-proxy.key".path;
          mode = "0600";
        };
        "kubernetes/pki/front-proxy-ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-kubernetes-front-proxy.crt";
          mode = "0644";
        };
        "kubernetes/pki/etcd/ca.key" = {
          source = config.age.secrets."ca-etcd.key".path;
          mode = "0600";
        };
        "kubernetes/pki/etcd/ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-etcd.crt";
          mode = "0644";
        };
        "kubernetes/pki/sa.key" = {
          source = config.age.secrets."sa-kubernetes.key".path;
          mode = "0600";
        };
        "kubernetes/pki/sa.pub" = {
          text = builtins.readFile "${inputs.self}/certs/sa-kubernetes.pub";
          mode = "0644";
        };
      };

      systemd.services = {
        init-kubernetes-cluster = {
          path = [
            pkgs.openssl
            pkgs.jq
            pkgs.curl
            pkgs.gawk
            pkgs.unstable.kubernetes
            pkgs.systemd
            pkgs.cri-tools
            pkgs.mount
            pkgs.util-linux
            pkgs.iproute2
          ]
          ++ pathPackages;
          description = "Initialize Kubernetes cluster";
          documentation = [ "https://kubernetes.io/docs" ];
          after = [ "crio.service" ];
          wantedBy = [ "multi-user.target" ];
          enableStrictShellChecks = true;

          script =
            let
              initConfiguration = ''
                apiVersion: kubeadm.k8s.io/v1beta4
                kind: InitConfiguration
                localAPIEndpoint:
                  advertiseAddress: "$ipAddr"
                  bindPort: ${toString cfg.apiServerPort}
                nodeRegistration:
                  kubeletExtraArgs:
                    - name: node-ip
                      value: "$ipAddr"
                ---
                apiVersion: kubeadm.k8s.io/v1beta4
                kind: ClusterConfiguration
                kubernetesVersion: ${cfg.kubernetesVersion}
                imageRepository: registry.k8s.io
                certificatesDir: /etc/kubernetes/pki
                controlPlaneEndpoint: "$clusterAddr"
                networking:
                  dnsDomain: cluster.local
              '';
            in
            ''
              if systemctl is-active --quiet kubelet.service; then
                echo "Kubernetes cluster is already initialized on this node, skipping initialization."
                exit 0
              fi

              ${waitForNetwork}
              ${waitForDns}

              clusterAddr="${clusterAddr}"
              ipAddr="${ipCommand}"

              if ${clusterTestCommand}; then
                  echo "Kubernetes API server is already running, skipping initialization of cluster."
                  exit 0
              else
              	echo "Initializing Kubernetes cluster..."

              	cat > /tmp/init-config.yaml <<-EOF
              		${indent 2 initConfiguration}
              	EOF

              	# Pull required images
                kubeadm config images pull --config /tmp/init-config.yaml

                kubeadm init \
                  --config /tmp/init-config.yaml \
                  --node-name="${config.networking.hostName}" \
                  --skip-certificate-key-print \
                  --skip-token-print \
                  --skip-phases="upload-config,upload-certs,mark-control-plane,bootstrap-token,kubelet-finalize,addon,show-join-command"

                ${restartTailscaleSvc}

              	until ${clusterTestCommand}; do
              		echo "Waiting for Kubernetes API server to be ready..."
              		sleep 1
              	done

                kubeadm init \
                  --config /tmp/init-config.yaml \
                  --node-name="${config.networking.hostName}" \
                  --skip-certificate-key-print \
                  --skip-token-print \
                  --skip-phases="preflight,certs,kubeconfig,etcd,control-plane,kubelet-start,addon"

                rm -f /tmp/init-config.yaml
              fi
            '';
        };

        join-kubernetes-cluster = {
          path = [
            pkgs.openssl
            pkgs.jq
            pkgs.curl
            pkgs.gawk
            pkgs.unstable.kubernetes
            pkgs.systemd
            pkgs.cri-tools
            pkgs.mount
            pkgs.util-linux
            pkgs.iproute2
          ]
          ++ pathPackages;
          description = "Join Kubernetes cluster";
          documentation = [ "https://kubernetes.io/docs" ];
          after = [
            "crio.service"
            "init-kubernetes-cluster.service"
          ];
          wantedBy = [ "multi-user.target" ];
          enableStrictShellChecks = true;

          script =
            let
              joinConfiguration = ''
                apiVersion: kubeadm.k8s.io/v1beta4
                kind: JoinConfiguration
                nodeRegistration:
                  kubeletExtraArgs:
                    - name: node-ip
                      value: "$ipAddr"
                controlPlane:
                  localAPIEndpoint:
                    advertiseAddress: "$ipAddr"
                    bindPort: ${toString cfg.apiServerPort}
                discovery:
                  bootstrapToken:
                    token: "$token"
                    apiServerEndpoint: "$clusterAddr"
                    caCertHashes:
                      - "sha256:$caCertHash"
              '';
            in
            ''
              ${mkCertFunction}
              ${mkKubeconfigFunction}

              if systemctl is-active --quiet kubelet.service; then
                echo "Kubernetes cluster is already running on this node, skipping joining."
                exit 0
              fi

              ${waitForNetwork}
              ${waitForDns}

              clusterAddr="${clusterAddr}"
              ipAddr="${ipCommand}"

              if ${clusterTestCommand}; then
                ${mkTempSuperAdminKubeconfig}

                token=$(kubeadm token create --kubeconfig=/etc/kubernetes/temp.conf)
                caCertHash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl ec -pubin -outform der | openssl dgst -sha256 -hex | sed 's/^.* //')

              	cat > /tmp/join-config.yaml <<-EOF
              		${indent 2 joinConfiguration}
              	EOF

                kubeadm join --config /tmp/join-config.yaml

                ${restartTailscaleSvc}

                rm -f /tmp/join-config.yaml
              else
                echo "Kubernetes API server is not reachable at ${clusterAddr}, cannot join cluster."
                exit 1
              fi
            '';
        };

        relabel-kubernetes-node =
          let
          in
          {
            path = [
              pkgs.openssl
              pkgs.jq
              pkgs.curl
              pkgs.gawk
              pkgs.unstable.kubernetes
              pkgs.systemd
              pkgs.cri-tools
              pkgs.mount
              pkgs.util-linux
              pkgs.iproute2
            ]
            ++ pathPackages;
            description = "Relabel Kubernetes node";
            documentation = [ "https://kubernetes.io/docs" ];
            after = [
              "init-kubernetes-cluster.service"
              "join-kubernetes-cluster.service"
            ];
            wantedBy = [ "multi-user.target" ];
            enableStrictShellChecks = true;

            script = ''
              ${mkCertFunction}
              ${mkKubeconfigFunction}

              if ! systemctl is-active --quiet kubelet.service; then
                echo "Kubernetes cluster is not initialized on this node, failing to relabel."
                exit 1
              fi

              ${waitForNetwork}
              ${waitForDns}

              clusterAddr="${clusterAddr}"

              if ${clusterTestCommand}; then
                ${mkTempSuperAdminKubeconfig}

                if ${toBooleanString isOnlyControlNode}; then
                  ${adminTempKubectl} taint node --overwrite=true ${config.networking.hostName} CriticalAddonsOnly=true:NoSchedule
                  ${adminTempKubectl} taint node --overwrite=true ${config.networking.hostName} node-role.kubernetes.io/control-plane=control-plane:NoSchedule
                  ${adminTempKubectl} label node ${config.networking.hostName} node-role.kubernetes.io/worker=worker- || true
                else
                  ${adminTempKubectl} taint node ${config.networking.hostName} CriticalAddonsOnly=true:NoSchedule- || true
                  ${adminTempKubectl} taint node ${config.networking.hostName} node-role.kubernetes.io/control-plane=control-plane:NoSchedule- || true
                fi

                if ${toBooleanString isOnlyWorkerNode}; then
                  ${adminTempKubectl} label node ${config.networking.hostName} node-role.kubernetes.io/control-plane=control-plane- || true
                fi

                if ${toBooleanString isControlAndWorker}; then
                  ${adminTempKubectl} taint node --overwrite=true ${config.networking.hostName} node-role.kubernetes.io/control-plane=control-plane:PreferNoSchedule
                fi

                if ${toBooleanString isControlPlane}; then
                  ${adminTempKubectl} label node --overwrite=true ${config.networking.hostName} node-role.kubernetes.io/control-plane=control-plane
                fi

                if ${toBooleanString isWorker}; then
                  ${adminTempKubectl} label node --overwrite=true ${config.networking.hostName} node-role.kubernetes.io/worker=worker
                fi

                ${adminTempKubectl} -n kube-system rollout restart deployment coredns
              else
                echo "Kubernetes API server is not reachable at ${clusterAddr}, cannot relabel node."
                exit 1
              fi
            '';
          };

        kubelet = {
          description = "Kubelet";
          documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
          after = [
            "init-kubernetes-cluster.service"
            "join-kubernetes-cluster.service"
            "relabel-kubernetes-node.service"
          ];
          requires = [ "crio.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [
            pkgs.unstable.kubernetes
            pkgs.coreutils
            pkgs.mount
            pkgs.util-linux
            pkgs.bash
          ];

          serviceConfig = {
            ExecCondition = ''
              ${pkgs.bash}/bin/bash -c "${pkgs.coreutils}/bin/test -f /etc/kubernetes/kubelet.conf || ${pkgs.coreutils}/bin/test -f /etc/kubernetes/bootstrap-kubelet.conf"
            '';
            EnvironmentFile = "-/var/lib/kubelet/kubeadm-flags.env";
            ExecStart = ''
              ${pkgs.kubernetes}/bin/kubelet \
                --config=/var/lib/kubelet/config.yaml \
                --kubeconfig=/etc/kubernetes/kubelet.conf \
                --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
                --v=2 \
                $KUBELET_KUBEADM_ARGS
            '';
            Restart = "on-failure";
            RestartSec = "5";
          };
        };
      };
    })
    (lib.mkIf (cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)) {
      nebulis.tailscale = {
        tags = [
          "kubernetes-control-plane"
        ];

        services = {
          "${cfg.tailscaleApiServerSvc}" = {
            mode = "tcp";
            port = 443;
            target = "127.0.0.1:${toString cfg.apiServerPort}";
            systemdConfig = {
              requisite = [ "kubelet.service" ];
              after = [
                "kubelet.service"
                "init-kubernetes-cluster.service"
                "join-kubernetes-cluster.service"
                "relabel-kubernetes-node.service"
              ];
            };
          };
        };
      };
    })
    {
      assertions = lib.mkIf cfg.enable [
        {
          assertion = cfg.enable -> (cfg.mode == "tailscale" -> tailscaleCfg.enable);
          message = "Error: Kubernetes control plane mode 'tailscale' requires Tailscale to be enabled.";
        }
        {
          assertion = cfg.enable -> (builtins.length cfg.kind) > 0;
          message = "Error: Kubernetes kind must have at least one of 'control-plane' or 'worker'.";
        }
      ];
    }
  ];
}

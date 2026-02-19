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

  clusterTestCommand = "curl --silent --fail --insecure \"https://${clusterAddr}/readyz\" --max-time 10 >/dev/null";

  readModuleFile = file: builtins.readFile "${inputs.self}/modules/hosts/kubernetes/${file}";
  readManifest = manifest: readModuleFile "manifests/${manifest}";

  kubeletManifest = readManifest "kubelet.yaml";

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

  adminKubectl = "kubectl --kubeconfig=/etc/kubernetes/admin.conf";

  addLabelOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/addLabelOnNode.sh"
  );
  removeLabelOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/removeLabelOnNode.sh"
  );
  addTaintOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/addTaintOnNode.sh"
  );
  removeTaintOnNodeFunction = builtins.replaceStrings [ "$KUBECTL" ] [ adminKubectl ] (
    readModuleFile "scripts/removeTaintOnNode.sh"
  );

in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
        kubernetes
        openssl
      ];

      age.secrets = {
        "ca-kubernetes.key".file = inputs.self + "/secrets/ca-kubernetes.key.age";
        "ca-etcd.key".file = inputs.self + "/secrets/ca-etcd.key.age";
        "ca-kubernetes-front-proxy.key".file = inputs.self + "/secrets/ca-kubernetes-front-proxy.key.age";
        "ca-typha.key".file = inputs.self + "/secrets/ca-typha.key.age";
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
        "kubernetes/pki/typha-ca.key" = {
          source = config.age.secrets."ca-typha.key".path;
          mode = "0600";
        };
        "kubernetes/pki/typha-ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-typha.crt";
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
            pkgs.kubernetes
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
              mkTempSuperAdminKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/temp.conf";
                username = "kubernetes-super-admin";
                group = "system:masters";
                expirationDays = 1;
                isLocal = false;
              };

              nodeIpPool = builtins.toJSON {
                apiVersion = "crd.projectcalico.org/v1";
                kind = "IPPool";
                metadata = {
                  name = "${config.networking.hostName}-ippool";
                };
                spec = {
                  cidr = "10.96.${toString cfg.nodeIndex}.0/24";
                  ipipMode = "Never";
                  natOutgoing = true;
                  disabled = false;
                  nodeSelector = "kubernetes.io/hostname == \"${config.networking.hostName}\"";
                };
              };

              mkCalicoTyphaCert = mkCert {
                ca = "/etc/kubernetes/pki/typha-ca";
                cert = "/etc/kubernetes/pki/typha";
                subject = {
                  CN = "calico-typha";
                };
                expirationDays = 365;
              };

              mkCalicoKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/calico-cni.conf";
                username = "calico-cni";
                expirationDays = 365;
                isLocal = true;
              };

              calicoClusterRole = readManifest "calico-cni.cluster-role.yaml";
              calicoTyphaClusterRole = readManifest "calico-typha.cluster-role.yaml";
              calicoTyphaDeployment = readManifest "calico-typha.deployment.yaml";
              calicoTyphaService = readManifest "calico-typha.service.yaml";

              tailscaleNetNsUpCommand =
                thenOrNull (cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind))
                  ''
                    tailscaleDns="${tailscaleDnsCommand}"
                    serviceIp="$(tailscale dns query "${cfg.tailscaleApiServerSvc}.$tailscaleDns" | grep ClassINET | awk '{print $5}')"

                    ip netns add vips0
                    ip link add veth-default type veth peer name veth-vips0
                    ip link set veth-vips0 netns vips0
                    ip addr add 172.31.0.1/24 dev veth-default
                    ip netns exec vips0 ip addr add 172.31.0.2/24 dev veth-vips0
                    ip link set veth-default up
                    ip netns exec vips0 ip link set veth-vips0 up
                    ip netns exec vips0 ip link set lo up
                    ip netns exec vips0 ip route add default via 172.31.0.1
                    iptables -t nat -I PREROUTING 1 -i veth-default -p tcp -d "$serviceIp" --dport 443 -j DNAT --to-destination "$ipAddr:${toString cfg.apiServerPort}"
                    iptables -I INPUT 1 -i veth-default -d "$ipAddr" -p tcp --dport ${toString cfg.apiServerPort} -j ACCEPT
                  '';
              tailscaleNetNsDownCommand =
                thenOrNull (cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind))
                  ''
                    kill -2 $kubeletSocatPID
                    kill -2 $controllerSocatPID
                    kill -2 $schedulerSocatPID

                    iptables -t nat -D PREROUTING -i veth-default -p tcp -d "$serviceIp" --dport 443 -j DNAT --to-destination "$ipAddr:${toString cfg.apiServerPort}"
                    iptables -D INPUT -i veth-default -d "$ipAddr" -p tcp --dport ${toString cfg.apiServerPort} -j ACCEPT
                    ip link set veth-default down
                    ip link del veth-default
                    ip netns del vips0
                  '';

              socatUpCommand = thenOrNull (cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)) ''
                socat tcp-connect:127.0.0.1:10248,fork,reuseaddr exec:'ip netns exec vips0 socat STDIO "tcp-listen:10248"',nofork 2>/dev/null &
                kubeletSocatPID=$!

                socat tcp-connect:127.0.0.1:10257,fork,reuseaddr exec:'ip netns exec vips0 socat STDIO "tcp-listen:10257"',nofork 2>/dev/null &
                controllerSocatPID=$!

                socat tcp-connect:127.0.0.1:10259,fork,reuseaddr exec:'ip netns exec vips0 socat STDIO "tcp-listen:10259"',nofork 2>/dev/null &
                schedulerSocatPID=$!
              '';

              socatDownCommand =
                thenOrNull (cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind))
                  ''
                    kill -2 $kubeletSocatPID
                    kill -2 $controllerSocatPID
                    kill -2 $schedulerSocatPID
                  '';

              netnsWrapper = thenOrNull (
                cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)
              ) "ip netns exec vips0";
            in
            ''
              ${mkCertFunction}
              ${mkKubeconfigFunction}

              ${waitForNetwork}
              ${waitForDns}

              clusterAddr="${clusterAddr}"
              ipAddr="${ipCommand}"

              ${thenOrNull (
                cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)
              ) "systemctl stop tailscale-${cfg.tailscaleApiServerSvc}-svc.service  || true"}

              if ${clusterTestCommand}; then
              	echo "Kubernetes API server is already running, skipping initialization of cluster."

                ${mkTempSuperAdminKubeconfig}

                kubeadm token create --kubeconfig=/etc/kubernetes/temp.conf --print-join-command > /tmp/join-command.sh
                sed -i '$s/$/ $@/' /tmp/join-command.sh
                rm -f /etc/kubernetes/temp.conf
                chmod +x /tmp/join-command.sh
                /tmp/join-command.sh \
                  ${thenOrNull (builtins.elem "control-plane" cfg.kind) "--control-plane --apiserver-advertise-address=\"$ipAddr\" --apiserver-bind-port=\"${toString cfg.apiServerPort}\" \\"}
                  --ignore-preflight-errors="FileAvailable--etc-kubernetes-pki-ca.crt"
                rm -f /tmp/join-command.sh

              	${adminKubectl} apply -f - <<-EOF
              		${indent 2 nodeIpPool}
              	EOF

                ${adminKubectl} -n kube-system rollout restart deployment coredns
              else
              	echo "Initializing Kubernetes cluster..."

              	# Pull required images
                kubeadm config images pull \
                  --image-repository="registry.k8s.io" \
                  --kubernetes-version="v1.34.3"

                kubeadm init \
                  --apiserver-advertise-address="$ipAddr" \
                  --apiserver-bind-port="${toString cfg.apiServerPort}" \
                  --cert-dir="/etc/kubernetes/pki" \
                  --control-plane-endpoint="$clusterAddr" \
                  --image-repository="registry.k8s.io" \
                  --kubernetes-version="v1.34.3" \
                  --node-name="${config.networking.hostName}" \
                  --service-dns-domain="cluster.local" \
                  --pod-network-cidr="${cfg.clusterIpRange}" \
                  --skip-certificate-key-print \
                  --skip-token-print \
                  --skip-phases="upload-config,upload-certs,mark-control-plane,bootstrap-token,kubelet-finalize,addon,show-join-command"

                ${tailscaleNetNsUpCommand}

              	until ${netnsWrapper} ${clusterTestCommand}; do
              		echo "Waiting for Kubernetes API server to be ready..."
              		sleep 1
              	done
                
                ${socatUpCommand}

                ${netnsWrapper} kubeadm init \
                  --apiserver-advertise-address="$ipAddr" \
                  --apiserver-bind-port="${toString cfg.apiServerPort}" \
                  --cert-dir="/etc/kubernetes/pki" \
                  --control-plane-endpoint="$clusterAddr" \
                  --image-repository="registry.k8s.io" \
                  --kubernetes-version="v1.34.3" \
                  --node-name="${config.networking.hostName}" \
                  --service-dns-domain="cluster.local" \
                  --pod-network-cidr="${cfg.clusterIpRange}" \
                  --skip-certificate-key-print \
                  --skip-token-print \
                  --skip-phases="preflight,certs,kubeconfig,etcd,control-plane,kubelet-start"

                ${socatDownCommand}

                curl -s "https://raw.githubusercontent.com/projectcalico/calico/${cfg.calicoVersion}/manifests/crds.yaml" \
                  | ${netnsWrapper} ${adminKubectl} apply -f -
                
              	${netnsWrapper} ${adminKubectl} apply -f - <<-EOF
              		${indent 2 nodeIpPool}
              	EOF
              
              	${netnsWrapper} ${adminKubectl} apply -f - <<-EOF
              		${indent 2 calicoClusterRole}
              	EOF

                ${netnsWrapper} ${adminKubectl} create clusterrolebinding calico-cni --clusterrole=calico-cni --user=calico-cni
                ${netnsWrapper} ${adminKubectl} create configmap -n kube-system calico-typha-ca --from-file=/etc/kubernetes/pki/typha-ca.crt

                ${mkCalicoTyphaCert}

                ${netnsWrapper} ${adminKubectl} create secret generic -n kube-system calico-typha-certs --from-file=/etc/kubernetes/pki/typha.key --from-file=/etc/kubernetes/pki/typha.crt
                ${netnsWrapper} ${adminKubectl} create serviceaccount -n kube-system calico-typha

              	${netnsWrapper} ${adminKubectl} apply -f - <<-EOF
              		${indent 2 calicoTyphaClusterRole}
              	EOF  

                ${netnsWrapper} ${adminKubectl} create clusterrolebinding calico-typha --clusterrole=calico-typha --serviceaccount=kube-system:calico-typha

              	${netnsWrapper} ${adminKubectl} apply -f - <<-EOF
              		${indent 2 calicoTyphaDeployment}
              	EOF

                ${tailscaleNetNsDownCommand}
              fi

              ${mkCalicoKubeconfig}

              ${thenOrNull (
                cfg.mode == "tailscale" && (builtins.elem "control-plane" cfg.kind)
              ) "systemctl start tailscale-${cfg.tailscaleApiServerSvc}-svc.service"}
            '';
        };
        kubelet = {
          description = "Kubelet";
          documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
          after = [
            "init-kubernetes-cluster.service"
          ];
          requires = [ "crio.service" ];
          wantedBy = [ "multi-user.target" ];
          before = [ "tailscale-svcs.target" ];
          path = [
            pkgs.kubernetes
            pkgs.coreutils
            pkgs.mount
            pkgs.util-linux
            pkgs.bash
          ];

          serviceConfig = {
            ExecCondition = ''
              ${pkgs.bash}/bin/bash -c "${pkgs.coreutils}/bin/test -f /etc/kubernetes/kubelet.conf || ${pkgs.coreutils}/bin/test -f /etc/kubernetes/bootstrap-kubelet.conf"
            '';
            ExecStart = ''
              ${pkgs.kubernetes}/bin/kubelet \
                --config=/var/lib/kubelet/config.yaml \
                --kubeconfig=/etc/kubernetes/kubelet.conf \
                --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
                --v=2
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
            requires = [ "kubelet.service" ];
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

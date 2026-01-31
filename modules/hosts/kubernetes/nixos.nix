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
  ) "$(tailscale dns status | grep -A1 'Search domains' | tail -n 1 | awk '{print $2}')";

  clusterAddr =
    if cfg.mode == "tailscale" then
      "${cfg.tailscaleApiServerSvc}.${tailscaleDnsCommand}:443"
    else
      "${cfg.apiServerHost}:${toString cfg.apiServerPort}";

  etcdClusterAddr =
    if cfg.mode == "tailscale" then
      "${cfg.tailscaleEtcdSvc}.${tailscaleDnsCommand}:443"
    else
      "${cfg.apiServerHost}:${toString cfg.etcdPeerPort}";

  pathPackages =
    if cfg.mode == "tailscale" then
      [ tailscaleCfg.package ]
    else
      [
        pkgs.jq
        pkgs.iproute2
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
        "kubernetes/kubelet/config.yaml" = {
          text = kubeletManifest;
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
          ]
          ++ pathPackages;
          description = "Initialize Kubernetes cluster";
          documentation = [ "https://kubernetes.io/docs" ];
          after = [ "crio.service" ];
          wantedBy = [ "multi-user.target" ];
          enableStrictShellChecks = true;

          script =
            let
              mkApiServerCert = mkCert {
                ca = "/etc/kubernetes/pki/ca";
                cert = "/etc/kubernetes/pki/apiserver";
                subject = {
                  CN = "kube-apiserver";
                };
                altNames = {
                  IP = [
                    "10.96.0.1"
                    "$ipAddr"
                  ];
                  DNS = [
                    "kubernetes"
                    "kubernetes.default"
                    "kubernetes.default.svc"
                    "kubernetes.default.svc.cluster.local"
                    (thenOrNull (tailscaleDnsCommand != null) "$clusterAddr")
                    (thenOrNull (cfg.mode == "tailscale") cfg.tailscaleApiServerSvc)
                    config.networking.hostName
                  ];
                };
                expirationDays = 365;
              };

              mkKubeletClientCert = mkCert {
                ca = "/etc/kubernetes/pki/ca";
                cert = "/etc/kubernetes/pki/apiserver-kubelet-client";
                subject = {
                  CN = "kube-apiserver-kubelet-client";
                  O = "kubeadm:cluster-admins";
                };
                expirationDays = 365;
              };

              mkFrontProxyClientCert = mkCert {
                ca = "/etc/kubernetes/pki/front-proxy-ca";
                cert = "/etc/kubernetes/pki/front-proxy-client";
                subject = {
                  CN = "front-proxy-client";
                };
                expirationDays = 365;
              };

              mkEtcdServerCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/etcd/server";
                subject = {
                  CN = config.networking.hostName;
                };
                altNames = {
                  IP = [
                    "$ipAddr"
                    "127.0.0.1"
                    "::1"
                  ];
                  DNS = [
                    (thenOrNull (tailscaleDnsCommand != null) "$etcdClusterAddr")
                    (thenOrNull (cfg.mode == "tailscale") cfg.tailscaleEtcdSvc)
                    config.networking.hostName
                    "localhost"
                  ];
                };
                expirationDays = 365;
              };

              mkEtcdPeerCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/etcd/peer";
                subject = {
                  CN = config.networking.hostName;
                };
                altNames = {
                  IP = [
                    "$ipAddr"
                    "127.0.0.1"
                    "::1"
                  ];
                  DNS = [
                    (thenOrNull (tailscaleDnsCommand != null) "$etcdClusterAddr")
                    (thenOrNull (cfg.mode == "tailscale") cfg.tailscaleEtcdSvc)
                    config.networking.hostName
                    "localhost"
                  ];
                };
                expirationDays = 365;
              };

              mkEtcdHealthcheckClientCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/etcd/healthcheck-client";
                subject = {
                  CN = "kube-etcd-healthcheck-client";
                };
                expirationDays = 365;
              };

              mkEtcdApiServerClientCert = mkCert {
                ca = "/etc/kubernetes/pki/etcd/ca";
                cert = "/etc/kubernetes/pki/apiserver-etcd-client";
                subject = {
                  CN = "kube-apiserver-etcd-client";
                };
                expirationDays = 365;
              };

              mkKubeletKubeconfig =
                {
                  isLocal ? false,
                }:
                mkKubeconfig {
                  ca = "/etc/kubernetes/pki/ca";
                  kubeconfig = "/etc/kubernetes/kubelet.conf";
                  username = "system:node:${config.networking.hostName}";
                  group = "system:nodes";
                  expirationDays = 1;
                  isLocal = isLocal;
                };

              mkSuperAdminKubeconfig =
                {
                  isLocal ? false,
                }:
                mkKubeconfig {
                  ca = "/etc/kubernetes/pki/ca";
                  kubeconfig = "/etc/kubernetes/admin.conf";
                  username = "kubernetes-super-admin";
                  group = "system:masters";
                  expirationDays = 1;
                  isLocal = isLocal;
                };

              mkControllerManagerKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/controller-manager.conf";
                username = "system:kube-controller-manager";
                expirationDays = 365;
                isLocal = true;
              };

              mkSchedulerKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/scheduler.conf";
                username = "system:kube-scheduler";
                expirationDays = 365;
                isLocal = true;
              };

              mkCalicoKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/calico-cni.conf";
                username = "calico-cni";
                expirationDays = 365;
                isLocal = true;
              };

              etcdManifest = ''
                apiVersion: v1
                kind: Pod
                metadata:
                  annotations:
                    kubeadm.kubernetes.io/etcd.advertise-client-urls: https://$ipAddr:${toString cfg.etcdClientPort}
                  labels:
                    component: etcd
                    tier: control-plane
                  name: etcd
                  namespace: kube-system
                spec:
                  containers:
                  - command:
                    - etcd
                    - --name=${config.networking.hostName}
                    - --data-dir=/var/lib/etcd
                    - --advertise-client-urls=https://$ipAddr:${toString cfg.etcdClientPort}
                    - --listen-client-urls=https://127.0.0.1:${toString cfg.etcdClientPort},https://$ipAddr:${toString cfg.etcdClientPort}
                    - --initial-advertise-peer-urls=https://$ipAddr:${toString cfg.etcdPeerPort}
                    - --initial-cluster=${config.networking.hostName}=https://$ipAddr:${toString cfg.etcdPeerPort}
                    - --listen-metrics-urls=http://127.0.0.1:2381
                    - --listen-peer-urls=https://$ipAddr:${toString cfg.etcdPeerPort}
                    - --client-cert-auth=true
                    - --peer-client-cert-auth=true
                    - --feature-gates=InitialCorruptCheck=true
                    - --snapshot-count=10000
                    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
                    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
                    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
                    - --key-file=/etc/kubernetes/pki/etcd/server.key
                    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
                    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
                    - --watch-progress-notify-interval=5s
                    image: registry.k8s.io/etcd:3.6.5-0
                    imagePullPolicy: IfNotPresent
                    livenessProbe:
                      failureThreshold: 8
                      httpGet:
                        host: 127.0.0.1
                        path: /livez
                        port: probe-port
                        scheme: HTTP
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    name: etcd
                    ports:
                    - containerPort: 2381
                      name: probe-port
                      protocol: TCP
                    readinessProbe:
                      failureThreshold: 3
                      httpGet:
                        host: 127.0.0.1
                        path: /readyz
                        port: probe-port
                        scheme: HTTP
                      periodSeconds: 1
                      timeoutSeconds: 15
                    resources:
                      requests:
                        cpu: 100m
                        memory: 100Mi
                    startupProbe:
                      failureThreshold: 24
                      httpGet:
                        host: 127.0.0.1
                        path: /readyz
                        port: probe-port
                        scheme: HTTP
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    volumeMounts:
                    - mountPath: /var/lib/etcd
                      name: etcd-data
                    - mountPath: /etc/kubernetes/pki/etcd
                      name: etcd-certs
                  hostNetwork: true
                  priority: 2000001000
                  priorityClassName: system-node-critical
                  securityContext:
                    seccompProfile:
                      type: RuntimeDefault
                  volumes:
                  - hostPath:
                      path: /etc/kubernetes/pki/etcd
                      type: DirectoryOrCreate
                    name: etcd-certs
                  - hostPath:
                      path: /var/lib/etcd
                      type: DirectoryOrCreate
                    name: etcd-data
                status: {}
              '';

              apiServerManifest = ''
                apiVersion: v1
                kind: Pod
                metadata:
                  annotations:
                    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: $ipAddr:${toString cfg.apiServerPort}
                  labels:
                    component: kube-apiserver
                    tier: control-plane
                  name: kube-apiserver
                  namespace: kube-system
                spec:
                  containers:
                  - command:
                    - kube-apiserver
                    - --advertise-address=$ipAddr
                    - --allow-privileged=true
                    - --authorization-mode=Node,RBAC
                    - --client-ca-file=/etc/kubernetes/pki/ca.crt
                    - --enable-admission-plugins=NodeRestriction
                    - --enable-bootstrap-token-auth=true
                    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
                    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
                    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
                    - --etcd-servers=https://$ipAddr:${toString cfg.etcdClientPort}
                    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
                    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
                    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
                    - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
                    - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
                    - --requestheader-allowed-names=front-proxy-client
                    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
                    - --requestheader-extra-headers-prefix=X-Remote-Extra-
                    - --requestheader-group-headers=X-Remote-Group
                    - --requestheader-username-headers=X-Remote-User
                    - --secure-port=${toString cfg.apiServerPort}
                    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
                    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
                    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
                    - --service-cluster-ip-range=${cfg.clusterIpRange}
                    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
                    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
                    image: registry.k8s.io/kube-apiserver:v1.34.3
                    imagePullPolicy: IfNotPresent
                    livenessProbe:
                      failureThreshold: 8
                      httpGet:
                        host: $ipAddr
                        path: /livez
                        port: probe-port
                        scheme: HTTPS
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    name: kube-apiserver
                    ports:
                    - containerPort: ${toString cfg.apiServerPort}
                      name: probe-port
                      protocol: TCP
                    readinessProbe:
                      failureThreshold: 3
                      httpGet:
                        host: $ipAddr
                        path: /readyz
                        port: probe-port
                        scheme: HTTPS
                      periodSeconds: 1
                      timeoutSeconds: 15
                    resources:
                      requests:
                        cpu: 250m
                    startupProbe:
                      failureThreshold: 24
                      httpGet:
                        host: $ipAddr
                        path: /livez
                        port: probe-port
                        scheme: HTTPS
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    volumeMounts:
                    - mountPath: /etc/ssl/certs
                      name: ca-certs
                      readOnly: true
                    - mountPath: /etc/pki/tls/certs
                      name: etc-pki-tls-certs
                      readOnly: true
                    - mountPath: /etc/kubernetes/pki
                      name: k8s-certs
                      readOnly: true
                  hostNetwork: true
                  priority: 2000001000
                  priorityClassName: system-node-critical
                  securityContext:
                    seccompProfile:
                      type: RuntimeDefault
                  volumes:
                  - hostPath:
                      path: /etc/ssl/certs
                      type: DirectoryOrCreate
                    name: ca-certs
                  - hostPath:
                      path: /etc/pki/tls/certs
                      type: DirectoryOrCreate
                    name: etc-pki-tls-certs
                  - hostPath:
                      path: /etc/kubernetes/pki
                      type: DirectoryOrCreate
                    name: k8s-certs
                status: {}
              '';

              controllerManagerManifest = ''
                apiVersion: v1
                kind: Pod
                metadata:
                  labels:
                    component: kube-controller-manager
                    tier: control-plane
                  name: kube-controller-manager
                  namespace: kube-system
                spec:
                  containers:
                  - command:
                    - kube-controller-manager
                    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
                    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
                    - --bind-address=127.0.0.1
                    - --client-ca-file=/etc/kubernetes/pki/ca.crt
                    - --cluster-name=kubernetes
                    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
                    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
                    - --controllers=*,bootstrapsigner,tokencleaner
                    - --kubeconfig=/etc/kubernetes/controller-manager.conf
                    - --leader-elect=true
                    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
                    - --root-ca-file=/etc/kubernetes/pki/ca.crt
                    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
                    - --use-service-account-credentials=true
                    image: registry.k8s.io/kube-controller-manager:v1.34.3
                    imagePullPolicy: IfNotPresent
                    livenessProbe:
                      failureThreshold: 8
                      httpGet:
                        host: 127.0.0.1
                        path: /healthz
                        port: probe-port
                        scheme: HTTPS
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    name: kube-controller-manager
                    ports:
                    - containerPort: 10257
                      name: probe-port
                      protocol: TCP
                    resources:
                      requests:
                        cpu: 200m
                    startupProbe:
                      failureThreshold: 24
                      httpGet:
                        host: 127.0.0.1
                        path: /healthz
                        port: probe-port
                        scheme: HTTPS
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    volumeMounts:
                    - mountPath: /etc/ssl/certs
                      name: ca-certs
                      readOnly: true
                    - mountPath: /etc/pki/tls/certs
                      name: etc-pki-tls-certs
                      readOnly: true
                    - mountPath: /usr/libexec/kubernetes/kubelet-plugins/volume/exec
                      name: flexvolume-dir
                    - mountPath: /etc/kubernetes/pki
                      name: k8s-certs
                      readOnly: true
                    - mountPath: /etc/kubernetes/controller-manager.conf
                      name: kubeconfig
                      readOnly: true
                  hostNetwork: true
                  priority: 2000001000
                  priorityClassName: system-node-critical
                  securityContext:
                    seccompProfile:
                      type: RuntimeDefault
                  volumes:
                  - hostPath:
                      path: /etc/ssl/certs
                      type: DirectoryOrCreate
                    name: ca-certs
                  - hostPath:
                      path: /etc/pki/tls/certs
                      type: DirectoryOrCreate
                    name: etc-pki-tls-certs
                  - hostPath:
                      path: /usr/libexec/kubernetes/kubelet-plugins/volume/exec
                      type: DirectoryOrCreate
                    name: flexvolume-dir
                  - hostPath:
                      path: /etc/kubernetes/pki
                      type: DirectoryOrCreate
                    name: k8s-certs
                  - hostPath:
                      path: /etc/kubernetes/controller-manager.conf
                      type: FileOrCreate
                    name: kubeconfig
                status: {}
              '';

              schedulerManifest = ''
                apiVersion: v1
                kind: Pod
                metadata:
                  labels:
                    component: kube-scheduler
                    tier: control-plane
                  name: kube-scheduler
                  namespace: kube-system
                spec:
                  containers:
                  - command:
                    - kube-scheduler
                    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
                    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
                    - --bind-address=127.0.0.1
                    - --kubeconfig=/etc/kubernetes/scheduler.conf
                    - --leader-elect=true
                    image: registry.k8s.io/kube-scheduler:v1.34.3
                    imagePullPolicy: IfNotPresent
                    livenessProbe:
                      failureThreshold: 8
                      httpGet:
                        host: 127.0.0.1
                        path: /livez
                        port: probe-port
                        scheme: HTTPS
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    name: kube-scheduler
                    ports:
                    - containerPort: 10259
                      name: probe-port
                      protocol: TCP
                    readinessProbe:
                      failureThreshold: 3
                      httpGet:
                        host: 127.0.0.1
                        path: /readyz
                        port: probe-port
                        scheme: HTTPS
                      periodSeconds: 1
                      timeoutSeconds: 15
                    resources:
                      requests:
                        cpu: 100m
                    startupProbe:
                      failureThreshold: 24
                      httpGet:
                        host: 127.0.0.1
                        path: /livez
                        port: probe-port
                        scheme: HTTPS
                      initialDelaySeconds: 10
                      periodSeconds: 10
                      timeoutSeconds: 15
                    volumeMounts:
                    - mountPath: /etc/kubernetes/scheduler.conf
                      name: kubeconfig
                      readOnly: true
                  hostNetwork: true
                  priority: 2000001000
                  priorityClassName: system-node-critical
                  securityContext:
                    seccompProfile:
                      type: RuntimeDefault
                  volumes:
                  - hostPath:
                      path: /etc/kubernetes/scheduler.conf
                      type: FileOrCreate
                    name: kubeconfig
                status: {}
              '';

              kubeadmConfigMap = builtins.toJSON ({
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "kubeadm-config";
                  namespace = "kube-system";
                };
                data = {
                  ClusterConfiguration = ''
                    apiServer: {}
                    apiVersion: kubeadm.k8s.io/v1beta4
                    caCertificateValidityPeriod: 87600h0m0s
                    certificateValidityPeriod: 8760h0m0s
                    certificatesDir: /etc/kubernetes/pki
                    clusterName: kubernetes
                    controllerManager: {}
                    dns: {}
                    encryptionAlgorithm: RSA-2048
                    etcd:
                      local:
                        dataDir: /var/lib/etcd
                    imageRepository: registry.k8s.io
                    kind: ClusterConfiguration
                    kubernetesVersion: v1.34.3
                    networking:
                      dnsDomain: cluster.local
                      serviceSubnet: 10.96.0.0/12
                    proxy: {}
                    scheduler: {}
                  '';
                };
              });

              kubeadmConfigRules = builtins.toJSON ({
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "Role";
                metadata = {
                  name = "kubeadm:nodes-kubeadm-config";
                  namespace = "kube-system";
                };
                rules = [
                  {
                    apiGroups = [ "" ];
                    resourceNames = [ "kubeadm-config" ];
                    resources = [ "configmaps" ];
                    verbs = [ "get" ];
                  }
                ];
              });

              kubeadmRoleBinding = builtins.toJSON ({
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "RoleBinding";
                metadata = {
                  name = "kubeadm:nodes-kubeadm-config";
                  namespace = "kube-system";
                };
                roleRef = {
                  apiGroup = "rbac.authorization.k8s.io";
                  kind = "Role";
                  name = "kubeadm:nodes-kubeadm-config";
                };
                subjects = [
                  {
                    kind = "Group";
                    name = "system:nodes";
                  }
                  {
                    kind = "Group";
                    name = "system:bootstrappers:kubeadm:default-node-token";
                  }
                ];
              });

              kubeletConfigMap = builtins.toJSON ({
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "kubelet-config";
                  namespace = "kube-system";
                  annotations = {
                    "kubeadm.kubernetes.io/component-config.hash" =
                      "sha256:${builtins.hashString "sha256" kubeletManifest}";
                  };
                };
                data = {
                  kubelet = kubeletManifest;
                };
              });

              kubeletConfigRules = builtins.toJSON ({
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "Role";
                metadata = {
                  name = "kubeadm:kubelet-config";
                  namespace = "kube-system";
                };
                rules = [
                  {
                    apiGroups = [ "" ];
                    resourceNames = [ "kubelet-config" ];
                    resources = [ "configmaps" ];
                    verbs = [ "get" ];
                  }
                ];
              });

              kubletConfigRoleBinding = builtins.toJSON ({
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "RoleBinding";
                metadata = {
                  name = "kubeadm:kubelet-config";
                  namespace = "kube-system";
                };
                roleRef = {
                  apiGroup = "rbac.authorization.k8s.io";
                  kind = "Role";
                  name = "kubeadm:kubelet-config";
                };
                subjects = [
                  {
                    kind = "Group";
                    name = "system:nodes";
                  }
                  {
                    kind = "Group";
                    name = "system:bootstrappers:kubeadm:default-node-token";
                  }
                ];
              });

              labelKeysToAdd =
                (map (v: "node-role.kubernetes.io/" + v) cfg.kind)
                ++ (
                  if (builtins.elem "worker" cfg.kind) then
                    [ ]
                  else
                    [ "node.kubernetes.io/exclude-from-external-load-balancers" ]
                );
              labelKeysToRemove =
                (map (v: "node-role.kubernetes.io/" + v) (
                  builtins.filter (k: !(builtins.elem k cfg.kind)) [
                    "control-plane"
                    "worker"
                  ]
                ))
                ++ (
                  if (builtins.elem "worker" cfg.kind) then
                    [ "node.kubernetes.io/exclude-from-external-load-balancers" ]
                  else
                    [ ]
                );

              taintToAdd =
                if cfg.kind == [ "control-plane" ] then [ "node-role.kubernetes.io/control-plane" ] else [ ];
              taintToRemove =
                if cfg.kind != [ "control-plane" ] then [ "node-role.kubernetes.io/control-plane" ] else [ ];

              coreDnsConfigMap = builtins.toJSON ({
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "coredns";
                  namespace = "kube-system";
                };
                data = {
                  Corefile = ''
                    .:53 {
                      errors
                      health {
                        lameduck 5s
                      }
                      ready
                      kubernetes cluster.local in-addr.arpa ip6.arpa {
                        pods insecure
                        fallthrough in-addr.arpa ip6.arpa
                        ttl 30
                      }
                      prometheus :9153
                      forward . /etc/resolv.conf {
                        max_concurrent 1000
                      }
                      cache 30 {
                        disable success cluster.local
                        disable denial cluster.local
                      }
                      loop
                      reload
                      loadbalance
                    }
                  '';
                };
              });

              coreDnsRoleBinding = builtins.toJSON ({
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "ClusterRoleBinding";
                metadata = {
                  name = "system:coredns";
                };
                roleRef = {
                  apiGroup = "rbac.authorization.k8s.io";
                  kind = "ClusterRole";
                  name = "system:coredns";
                };
                subjects = [
                  {
                    kind = "ServiceAccount";
                    name = "coredns";
                    namespace = "kube-system";
                  }
                ];
              });

              coreDnsServiceAccount = builtins.toJSON ({
                apiVersion = "v1";
                kind = "ServiceAccount";
                metadata = {
                  name = "coredns";
                  namespace = "kube-system";
                };
              });

              coreDnsDeployment = builtins.toJSON ({
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  labels = {
                    "k8s-app" = "kube-dns";
                  };
                  name = "coredns";
                  namespace = "kube-system";
                };
                spec = {
                  replicas = 2;
                  selector = {
                    matchLabels = {
                      "k8s-app" = "kube-dns";
                    };
                  };
                  strategy = {
                    rollingUpdate = {
                      maxUnavailable = 1;
                    };
                    type = "RollingUpdate";
                  };
                  template = {
                    metadata = {
                      labels = {
                        "k8s-app" = "kube-dns";
                      };
                    };
                    spec = {
                      affinity = {
                        podAntiAffinity = {
                          preferredDuringSchedulingIgnoredDuringExecution = [
                            {
                              podAffinityTerm = {
                                labelSelector = {
                                  matchExpressions = [
                                    {
                                      key = "k8s-app";
                                      operator = "In";
                                      values = [ "kube-dns" ];
                                    }
                                  ];
                                };
                                topologyKey = "kubernetes.io/hostname";
                              };
                              weight = 100;
                            }
                          ];
                        };
                      };
                      containers = [
                        {
                          args = [
                            "-conf"
                            "/etc/coredns/Corefile"
                          ];
                          image = "registry.k8s.io/coredns/coredns:v1.12.1";
                          imagePullPolicy = "IfNotPresent";
                          livenessProbe = {
                            failureThreshold = 5;
                            httpGet = {
                              path = "/health";
                              port = "liveness-probe";
                              scheme = "HTTP";
                            };
                            initialDelaySeconds = 60;
                            successThreshold = 1;
                            timeoutSeconds = 5;
                          };
                          name = "coredns";
                          ports = [
                            {
                              containerPort = 53;
                              name = "dns";
                              protocol = "UDP";
                            }
                            {
                              containerPort = 53;
                              name = "dns-tcp";
                              protocol = "TCP";
                            }
                            {
                              containerPort = 9153;
                              name = "metrics";
                              protocol = "TCP";
                            }
                            {
                              containerPort = 8080;
                              name = "liveness-probe";
                              protocol = "TCP";
                            }
                            {
                              containerPort = 8181;
                              name = "readiness-probe";
                              protocol = "TCP";
                            }
                          ];
                          readinessProbe = {
                            httpGet = {
                              path = "/ready";
                              port = "readiness-probe";
                              scheme = "HTTP";
                            };
                          };
                          resources = {
                            limits = {
                              memory = "170Mi";
                            };
                            requests = {
                              cpu = "100m";
                              memory = "70Mi";
                            };
                          };
                          securityContext = {
                            allowPrivilegeEscalation = false;
                            capabilities = {
                              add = [ "NET_BIND_SERVICE" ];
                              drop = [ "ALL" ];
                            };
                            readOnlyRootFilesystem = true;
                          };
                          volumeMounts = [
                            {
                              mountPath = "/etc/coredns";
                              name = "config-volume";
                              readOnly = true;
                            }
                          ];
                        }
                      ];
                      dnsPolicy = "Default";
                      nodeSelector = {
                        "kubernetes.io/os" = "linux";
                      };
                      priorityClassName = "system-cluster-critical";
                      serviceAccountName = "coredns";
                      tolerations = [
                        {
                          key = "CriticalAddonsOnly";
                          operator = "Exists";
                        }
                        {
                          effect = "NoSchedule";
                          key = "node-role.kubernetes.io/control-plane";
                        }
                      ];
                      volumes = [
                        {
                          configMap = {
                            items = [
                              {
                                key = "Corefile";
                                path = "Corefile";
                              }
                            ];
                            name = "coredns";
                          };
                          name = "config-volume";
                        }
                      ];
                    };
                  };
                };
                status = { };
              });

              coreDnsService = builtins.toJSON ({
                apiVersion = "v1";
                kind = "Service";
                metadata = {
                  annotations = {
                    "prometheus.io/port" = "9153";
                    "prometheus.io/scrape" = "true";
                  };
                  labels = {
                    "k8s-app" = "kube-dns";
                    "kubernetes.io/cluster-service" = "true";
                    "kubernetes.io/name" = "CoreDNS";
                  };
                  name = "kube-dns";
                  namespace = "kube-system";
                  resourceVersion = "0";
                };
                spec = {
                  clusterIP = "10.96.0.10";
                  ports = [
                    {
                      name = "dns";
                      port = 53;
                      protocol = "UDP";
                      targetPort = 53;
                    }
                    {
                      name = "dns-tcp";
                      port = 53;
                      protocol = "TCP";
                      targetPort = 53;
                    }
                    {
                      name = "metrics";
                      port = 9153;
                      protocol = "TCP";
                      targetPort = 9153;
                    }
                  ];
                  selector = {
                    "k8s-app" = "kube-dns";
                  };
                };
                status = {
                  loadBalancer = { };
                };
              });

              kubeProxyConfig = ''
                apiVersion: kubeproxy.config.k8s.io/v1alpha1
                bindAddress: 0.0.0.0
                bindAddressHardFail: false
                clientConnection:
                  acceptContentTypes: ""
                  burst: 0
                  contentType: ""
                  kubeconfig: /var/lib/kube-proxy/kubeconfig.conf
                  qps: 0
                clusterCIDR: ""
                configSyncPeriod: 0s
                conntrack:
                  maxPerCore: null
                  min: null
                  tcpBeLiberal: false
                  tcpCloseWaitTimeout: null
                  tcpEstablishedTimeout: null
                  udpStreamTimeout: 0s
                  udpTimeout: 0s
                detectLocal:
                  bridgeInterface: ""
                  interfaceNamePrefix: ""
                detectLocalMode: ""
                enableProfiling: false
                healthzBindAddress: ""
                hostnameOverride: ""
                iptables:
                  localhostNodePorts: null
                  masqueradeAll: false
                  masqueradeBit: null
                  minSyncPeriod: 0s
                  syncPeriod: 0s
                ipvs:
                  excludeCIDRs: null
                  minSyncPeriod: 0s
                  scheduler: ""
                  strictARP: false
                  syncPeriod: 0s
                  tcpFinTimeout: 0s
                  tcpTimeout: 0s
                  udpTimeout: 0s
                kind: KubeProxyConfiguration
                logging:
                  flushFrequency: 0
                  options:
                    json:
                      infoBufferSize: "0"
                    text:
                      infoBufferSize: "0"
                  verbosity: 0
                metricsBindAddress: ""
                mode: ""
                nftables:
                  masqueradeAll: false
                  masqueradeBit: null
                  minSyncPeriod: 0s
                  syncPeriod: 0s
                nodePortAddresses: null
                oomScoreAdj: null
                portRange: ""
                showHiddenMetricsForVersion: ""
                winkernel:
                  enableDSR: false
                  forwardHealthCheckVip: false
                  networkName: ""
                  rootHnsEndpointName: ""
                  sourceVip: ""
              '';

              kubeProxyKubeconfig = ''
                apiVersion: v1
                kind: Config
                clusters:
                - cluster:
                    certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
                    server: https://$clusterAddr
                  name: default
                contexts:
                - context:
                    cluster: default
                    namespace: default
                    user: default
                  name: default
                current-context: default
                users:
                - name: default
                  user:
                    tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
              '';

              kubeProxyConfigMap = (
                builtins.toJSON ({
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  metadata = {
                    name = "kube-proxy";
                    namespace = "kube-system";
                    annotations = {
                      "kubeadm.kubernetes.io/component-config.hash" = "sha256:${
                        builtins.hashString "sha256" (kubeProxyConfig + kubeProxyKubeconfig)
                      }";
                    };
                    labels = {
                      app = "kube-proxy";
                    };
                  };
                  data = {
                    "config.conf" = kubeProxyConfig;
                    "kubeconfig.conf" = kubeProxyKubeconfig;
                  };
                })
              );

              kubeProxyDaemonSet = lib.escape [ "$(" ] (
                builtins.toJSON ({
                  apiVersion = "apps/v1";
                  kind = "DaemonSet";
                  metadata = {
                    labels = {
                      "k8s-app" = "kube-proxy";
                    };
                    name = "kube-proxy";
                    namespace = "kube-system";
                  };
                  spec = {
                    selector = {
                      matchLabels = {
                        "k8s-app" = "kube-proxy";
                      };
                    };
                    template = {
                      metadata = {
                        labels = {
                          "k8s-app" = "kube-proxy";
                        };
                      };
                      spec = {
                        containers = [
                          {
                            command = [
                              "/usr/local/bin/kube-proxy"
                              "--config=/var/lib/kube-proxy/config.conf"
                              "--hostname-override=$(NODE_NAME)"
                            ];
                            env = [
                              {
                                name = "NODE_NAME";
                                valueFrom = {
                                  fieldRef = {
                                    fieldPath = "spec.nodeName";
                                  };
                                };
                              }
                            ];
                            image = "registry.k8s.io/kube-proxy:v1.34.3";
                            imagePullPolicy = "IfNotPresent";
                            name = "kube-proxy";
                            resources = { };
                            securityContext = {
                              privileged = true;
                            };
                            volumeMounts = [
                              {
                                mountPath = "/var/lib/kube-proxy";
                                name = "kube-proxy";
                              }
                              {
                                mountPath = "/run/xtables.lock";
                                name = "xtables-lock";
                              }
                              {
                                mountPath = "/lib/modules";
                                name = "lib-modules";
                                readOnly = true;
                              }
                            ];
                          }
                        ];
                        hostNetwork = true;
                        nodeSelector = {
                          "kubernetes.io/os" = "linux";
                        };
                        priorityClassName = "system-node-critical";
                        serviceAccountName = "kube-proxy";
                        tolerations = [
                          {
                            operator = "Exists";
                          }
                        ];
                        volumes = [
                          {
                            configMap = {
                              name = "kube-proxy";
                            };
                            name = "kube-proxy";
                          }
                          {
                            hostPath = {
                              path = "/run/xtables.lock";
                              type = "FileOrCreate";
                            };
                            name = "xtables-lock";
                          }
                          {
                            hostPath = {
                              path = "/lib/modules";
                            };
                            name = "lib-modules";
                          }
                        ];
                      };
                    };
                    updateStrategy = {
                      type = "RollingUpdate";
                    };
                  };
                  status = {
                    currentNumberScheduled = 0;
                    desiredNumberScheduled = 0;
                    numberMisscheduled = 0;
                    numberReady = 0;
                  };
                })
              );

              kubeProxyServiceAccount = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "v1";
                  kind = "ServiceAccount";
                  metadata = {
                    name = "kube-proxy";
                    namespace = "kube-system";
                  };
                })
              );

              kubeProxyRoleBinding = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "rbac.authorization.k8s.io/v1";
                  kind = "ClusterRoleBinding";
                  metadata = {
                    name = "kube-proxy";
                  };
                  roleRef = {
                    apiGroup = "rbac.authorization.k8s.io";
                    kind = "ClusterRole";
                    name = "system:node-proxier";
                  };
                  subjects = [
                    {
                      kind = "ServiceAccount";
                      name = "kube-proxy";
                      namespace = "kube-system";
                    }
                  ];
                })
              );

              kubeProxyRole = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "rbac.authorization.k8s.io/v1";
                  kind = "Role";
                  metadata = {
                    name = "kube-proxy";
                  };
                  rules = [
                    {
                      apiGroups = [ "" ];
                      resourceNames = [ "kube-proxy" ];
                      resources = [ "configmaps" ];
                      verbs = [ "get" ];
                    }
                  ];
                })
              );

              kubeProxyRoleBindingNode = lib.escape [ "$" ] (
                builtins.toJSON ({
                  apiVersion = "rbac.authorization.k8s.io/v1";
                  kind = "RoleBinding";
                  metadata = {
                    name = "kube-proxy";
                    namespace = "kube-system";
                  };
                  roleRef = {
                    apiGroup = "rbac.authorization.k8s.io";
                    kind = "Role";
                    name = "kube-proxy";
                  };
                  subjects = [
                    {
                      kind = "Group";
                      name = "system:nodes";
                    }
                    {
                      kind = "Group";
                      name = "system:bootstrappers:kubeadm:default-node-token";
                    }
                  ];
                })
              );

              calicoClusterRole = readManifest "calico-cni.cluster-role.yaml";
              calicoClusterRoleBinding = readManifest "calico-cni.cluster-role-binding.yaml";

              addLabelsOnNodeCall = lib.strings.concatMapStringsSep "\n" (
                label: "addLabelOnNode \"${config.networking.hostName}\" \"${label}\""
              ) labelKeysToAdd;
              removeLabelsOnNodeCall = lib.strings.concatMapStringsSep "\n" (
                label: "removeLabelOnNode \"${config.networking.hostName}\" \"${label}\""
              ) labelKeysToRemove;
              addTaintsOnNodeCall = lib.strings.concatMapStringsSep "\n" (
                taint: "addTaintOnNode \"${config.networking.hostName}\" \"${taint}\""
              ) taintToAdd;
              removeTaintsOnNodeCall = lib.strings.concatMapStringsSep "\n" (
                taint: "removeTaintOnNode \"${config.networking.hostName}\" \"${taint}\""
              ) taintToRemove;

              crictl = "${pkgs.cri-tools}/bin/crictl";
            in
            ''
              ${mkCertFunction}
              ${mkKubeconfigFunction}
              ${addLabelOnNodeFunction}
              ${removeLabelOnNodeFunction}
              ${addTaintOnNodeFunction}
              ${removeTaintOnNodeFunction}

              ${waitForNetwork}

              clusterAddr="${clusterAddr}"
              ipAddr="${ipCommand}"
              etcdClusterAddr="${etcdClusterAddr}"

              if curl --silent --fail --insecure "https://$clusterAddr/livez" --max-time 10 >/dev/null; then
              	echo "Kubernetes API server is already running, skipping initialization of cluster."

              	${mkKubeletKubeconfig { }}
              	${mkSuperAdminKubeconfig { }}
                ${mkCalicoKubeconfig}

              	kubelet --config=/etc/kubernetes/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf &
              	kubeletPid=$!

              	sleep 5

              	${removeLabelsOnNodeCall}
              	${addLabelsOnNodeCall}
              	${removeTaintsOnNodeCall}
              	${addTaintsOnNodeCall}

              	kill -2 $kubeletPid
              else
              	echo "Initializing Kubernetes cluster..."

              	# Pull required images
              	${crictl} pull registry.k8s.io/kube-apiserver:v1.34.3 # Make version consistent
              	${crictl} pull registry.k8s.io/kube-controller-manager:v1.34.3  # Make version consistent
              	${crictl} pull registry.k8s.io/kube-scheduler:v1.34.3  # Make version consistent
              	${crictl} pull registry.k8s.io/etcd:3.6.5-0 # Make version consistent

              	${mkApiServerCert}
              	${mkKubeletClientCert}
              	${mkFrontProxyClientCert}
              	${mkEtcdServerCert}
              	${mkEtcdPeerCert}
              	${mkEtcdHealthcheckClientCert}
              	${mkEtcdApiServerClientCert}

              	${mkKubeletKubeconfig { isLocal = true; }}
              	${mkSuperAdminKubeconfig { isLocal = true; }}
              	${mkControllerManagerKubeconfig}
              	${mkSchedulerKubeconfig}
                ${mkCalicoKubeconfig}

              	mkdir -p /etc/kubernetes/manifests

              	cat > /etc/kubernetes/manifests/etcd.yaml <<-EOF
              		${indent 2 etcdManifest}
              	EOF

              	chmod 644 /etc/kubernetes/manifests/etcd.yaml

              	cat > /etc/kubernetes/manifests/kube-apiserver.yaml <<-EOF
              		${indent 2 apiServerManifest}
              	EOF

              	chmod 644 /etc/kubernetes/manifests/kube-apiserver.yaml

              	cat > /etc/kubernetes/manifests/kube-controller-manager.yaml <<-EOF
              		${indent 2 controllerManagerManifest}
              	EOF

              	chmod 644 /etc/kubernetes/manifests/kube-controller-manager.yaml

              	cat > /etc/kubernetes/manifests/kube-scheduler.yaml <<-EOF
              		${indent 2 schedulerManifest}
              	EOF

              	chmod 644 /etc/kubernetes/manifests/kube-scheduler.yaml

              	kubelet --config=/etc/kubernetes/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf --v=2 &

              	kubeletPid=$!

              	# wait for kubelet to create the static pods

              	sleep 15

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 calicoClusterRole}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 calicoClusterRoleBinding}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeadmConfigMap}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeadmConfigRules}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeadmRoleBinding}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeletConfigMap}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeletConfigRules}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubletConfigRoleBinding}
              	EOF

              	${removeLabelsOnNodeCall}
              	${addLabelsOnNodeCall}
              	${removeTaintsOnNodeCall}
              	${addTaintsOnNodeCall}

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 coreDnsConfigMap}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 coreDnsRoleBinding}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 coreDnsServiceAccount}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 coreDnsDeployment}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 coreDnsService}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeProxyConfigMap}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeProxyDaemonSet}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeProxyServiceAccount}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeProxyRoleBinding}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeProxyRole}
              	EOF

              	${adminKubectl} create -f - <<-EOF
              		${indent 2 kubeProxyRoleBindingNode}
              	EOF

              	kill -2 $kubeletPid

              	rm -f /etc/kubernetes/admin.conf
                
              	${mkSuperAdminKubeconfig { }}

                systemctl start kubelet.service
              fi
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
          path = [
            pkgs.kubernetes
            pkgs.coreutils
            pkgs.mount
          ];

          serviceConfig = {
            ExecCondition = ''
              ${pkgs.coreutils}/bin/test -f /etc/kubernetes/kubelet.conf
            '';
            ExecStart = ''
              ${pkgs.kubernetes}/bin/kubelet \
                --config=/etc/kubernetes/kubelet/config.yaml \
                --kubeconfig=/etc/kubernetes/kubelet.conf \
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

          "${cfg.tailscaleEtcdSvc}" = {
            mode = "tcp";
            port = 443;
            target = "127.0.0.1:${toString cfg.etcdClientPort}";
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

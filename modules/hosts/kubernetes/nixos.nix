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

  ipCommand =
    if cfg.mode == "tailscale" then
      "$(tailscale ip -4)"
    else
      # Ensure no IPv6 addresses are returned nor the loopback address
      "$(ip -json -br a | jq '[.[] | .addr_info[] | select(.prefixlen > 32 | not) | select(.local != \"127.0.0.1\") | .local][0]' -r)";

  tailscaleDnsCommand =
    if cfg.mode == "tailscale" then
      "$(tailscale dns status | grep -A1 'Search domains' | tail -n 1 | awk '{print $2}')"
    else
      null;

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
        # "kubernetes/kubelet/config.yaml" = {
        #   text = ''
        #     apiVersion: kubelet.config.k8s.io/v1beta1
        #     authentication:
        #       anonymous:
        #         enabled: false
        #       webhook:
        #         cacheTTL: 0s
        #         enabled: true
        #       x509:
        #         clientCAFile: /etc/kubernetes/pki/ca.crt
        #     authorization:
        #       mode: Webhook
        #       webhook:
        #         cacheAuthorizedTTL: 0s
        #         cacheUnauthorizedTTL: 0s
        #     cgroupDriver: systemd
        #     clusterDNS:
        #     - 10.96.0.10
        #     clusterDomain: cluster.local
        #     containerRuntimeEndpoint: unix:///var/run/crio/crio.sock
        #     cpuManagerReconcilePeriod: 0s
        #     crashLoopBackOff: {}
        #     evictionPressureTransitionPeriod: 0s
        #     fileCheckFrequency: 0s
        #     healthzBindAddress: 127.0.0.1
        #     healthzPort: 10248
        #     httpCheckFrequency: 0s
        #     imageMaximumGCAge: 0s
        #     imageMinimumGCAge: 0s
        #     kind: KubeletConfiguration
        #     logging:
        #       flushFrequency: 0
        #       options:
        #         json:
        #           infoBufferSize: "0"
        #         text:
        #           infoBufferSize: "0"
        #       verbosity: 0
        #     memorySwap: {}
        #     nodeStatusReportFrequency: 0s
        #     nodeStatusUpdateFrequency: 0s
        #     rotateCertificates: true
        #     runtimeRequestTimeout: 0s
        #     shutdownGracePeriod: 0s
        #     shutdownGracePeriodCriticalPods: 0s
        #     staticPodPath: /etc/kubernetes/manifests
        #     streamingConnectionIdleTimeout: 0s
        #     syncFrequency: 0s
        #     volumeStatsAggPeriod: 0s
        #   '';
        #   mode = "0644";
        # };
      };

      systemd.services = {
        init-kubernetes-cluster = {
          path = [
            pkgs.openssl
            pkgs.jq
            pkgs.curl
            pkgs.gawk
          ]
          ++ pathPackages;
          description = "Initialize Kubernetes cluster";
          documentation = [ "https://kubernetes.io/docs" ];
          wantedBy = [ "multi-user.target" ];
          enableStrictShellChecks = true;

          script =
            let
              clusterAddr =
                if cfg.mode == "tailscale" then
                  "${cfg.tailscaleApiServerSvc}.${tailscaleDnsCommand}:443"
                else
                  "${cfg.apiServerHost}:${toString cfg.apiServerPort}";

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
                  subjectArg = if subjectString == "" then "" else "-subj \"${subjectString}\"";

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
                ''
                  if [ ! -f "${ca}.crt" ] || [ ! -f "${ca}.key" ]; then
                    echo "Required ${ca} CA is missing, cannot create ${cert} certificate."
                    exit 1
                  fi

                  if [ ! -f "${cert}.key" ]; then
                    openssl genpkey -algorithm ED25519 -out "${cert}.key"
                    chmod 600 "${cert}.key"
                  fi

                  if [ ! -f "${cert}.crt" ] || ! openssl x509 -checkend 86400 -noout -in "${cert}.crt"; then
                    openssl req -new \
                      -key "${cert}.key" \
                      ${subjectArg} \
                      ${altNamesExtArg} \
                      -out "${cert}.csr"

                    openssl x509 -req \
                      -in "${cert}.csr" \
                      -CA "${ca}.crt" \
                      -CAkey "${ca}.key" \
                      -out "${cert}.crt" \
                      -days ${toString expirationDays} \
                      ${altNamesExtFileArg} \
                      -sha512
                    
                    chmod 644 "${cert}.crt"
                    rm -f "${cert}.csr"
                  fi
                '';

              mkKubeconfig =
                {
                  ca,
                  kubeconfig,
                  username,
                  group ? "",
                  expirationDays,
                }:
                let
                  subject =
                    if group == "" then
                      { CN = username; }
                    else
                      {
                        CN = username;
                        O = group;
                      };

                  subjectString = lib.strings.concatStrings (
                    lib.attrsets.mapAttrsToList (k: v: "/${k}=${v}") subject
                  );
                  subjectArg = if subjectString == "" then "" else "-subj \"${subjectString}\"";
                in
                ''
                  ${waitForNetwork}

                  if [ ! -f "${ca}.crt" ] || [ ! -f "${ca}.key" ]; then
                    echo "Required ${ca} CA is missing, cannot create ${kubeconfig} kubeconfig."
                    exit 1
                  fi

                  # TODO: handle expiration of kubeconfig
                  if [ ! -f ${kubeconfig} ]; then
                    openssl genpkey -algorithm ED25519 -out "${kubeconfig}.key"

                    openssl req -new \
                      -key "${kubeconfig}.key" \
                      ${subjectArg} \
                      -out "${kubeconfig}.csr"

                    openssl x509 -req \
                      -in "${kubeconfig}.csr" \
                      -CA "${ca}.crt" \
                      -CAkey "${ca}.key" \
                      -out "${kubeconfig}.crt" \
                      -days ${toString expirationDays} \
                      -sha512

                    jq -ncr \
                      --arg caData "$(base64 -w0 ${ca}.crt)" \
                      --arg clientCertData "$(base64 -w0 ${kubeconfig}.crt)" \
                      --arg clientKeyData "$(base64 -w0 ${kubeconfig}.key)" \
                      --arg clusterAddr "${clusterAddr}" \
                      '{
                        apiVersion: "v1",
                        kind: "Config",
                        clusters: [
                          {
                            name: "kubernetes",
                            cluster: {
                              "certificate-authority-data": $caData,
                              server: "https://" + $clusterAddr
                            }
                          }
                        ],
                        contexts: [
                          {
                            name: "${username}@kubernetes",
                            context: {
                              cluster: "kubernetes",
                              user: "${username}"
                            }
                          }
                        ],
                        "current-context": "${username}@kubernetes",
                        users: [
                          {
                            name: "${username}",
                            user: {
                              "client-certificate-data": $clientCertData,
                              "client-key-data": $clientKeyData
                            }
                          }
                        ]
                      }' > "${kubeconfig}"

                    rm -f "${kubeconfig}.key" "${kubeconfig}.csr" "${kubeconfig}.crt"

                    chmod 600 "${kubeconfig}"
                  fi
                '';

              mkApiServerCert = mkCert {
                ca = "/etc/kubernetes/pki/ca";
                cert = "/etc/kubernetes/pki/apiserver";
                subject = {
                  CN = "kube-apiserver";
                };
                altNames = {
                  IP = [
                    "10.96.0.1"
                    ipCommand
                  ];
                  DNS = [
                    "kubernetes"
                    "kubernetes.default"
                    "kubernetes.default.svc"
                    "kubernetes.default.svc.cluster.local"
                    (
                      if tailscaleDnsCommand != null then "${cfg.tailscaleApiServerSvc}.${tailscaleDnsCommand}" else null
                    )
                    (if cfg.mode == "tailscale" then cfg.tailscaleApiServerSvc else null)
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
                    ipCommand
                    "127.0.0.1"
                    "::1"
                  ];
                  DNS = [
                    (if tailscaleDnsCommand != null then "${cfg.tailscaleEtcdSvc}.${tailscaleDnsCommand}" else null)
                    (if cfg.mode == "tailscale" then cfg.tailscaleEtcdSvc else null)
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
                    ipCommand
                    "127.0.0.1"
                    "::1"
                  ];
                  DNS = [
                    (if tailscaleDnsCommand != null then "${cfg.tailscaleEtcdSvc}.${tailscaleDnsCommand}" else null)
                    (if cfg.mode == "tailscale" then cfg.tailscaleEtcdSvc else null)
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

              mkKubeletKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/kubelet.conf";
                username = "system:node:${config.networking.hostName}";
                group = "system:nodes";
                expirationDays = 1;
              };

              mkControllerManagerKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/controller-manager.conf";
                username = "system:kube-controller-manager";
                expirationDays = 365;
              };

              mkSchedulerKubeconfig = mkKubeconfig {
                ca = "/etc/kubernetes/pki/ca";
                kubeconfig = "/etc/kubernetes/scheduler.conf";
                username = "system:kube-scheduler";
                expirationDays = 365;
              };

              etcdManifest = ''
                apiVersion: v1
                kind: Pod
                metadata:
                  annotations:
                    kubeadm.kubernetes.io/etcd.advertise-client-urls: https://${ipCommand}:${toString cfg.etcdClientPort}
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
                    - --advertise-client-urls=https://${ipCommand}:${toString cfg.etcdClientPort}
                    - --listen-client-urls=https://127.0.0.1:${toString cfg.etcdClientPort},https://${ipCommand}:${toString cfg.etcdClientPort}
                    - --initial-advertise-peer-urls=https://${ipCommand}:${toString cfg.etcdPeerPort}
                    - --initial-cluster=${config.networking.hostName}=https://${ipCommand}:${toString cfg.etcdPeerPort}
                    - --listen-metrics-urls=http://127.0.0.1:2381
                    - --listen-peer-urls=https://${ipCommand}:${toString cfg.etcdPeerPort}
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
                    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: ${ipCommand}:${toString cfg.apiServerPort}
                  labels:
                    component: kube-apiserver
                    tier: control-plane
                  name: kube-apiserver
                  namespace: kube-system
                spec:
                  containers:
                  - command:
                    - kube-apiserver
                    - --advertise-address=${ipCommand}
                    - --allow-privileged=true
                    - --authorization-mode=Node,RBAC
                    - --client-ca-file=/etc/kubernetes/pki/ca.crt
                    - --enable-admission-plugins=NodeRestriction
                    - --enable-bootstrap-token-auth=true
                    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
                    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
                    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
                    - --etcd-servers=https://${ipCommand}:${toString cfg.etcdClientPort}
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
                        host: ${ipCommand}
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
                        host: ${ipCommand}
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
                        host: ${ipCommand}
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
            in
            ''
              ${waitForNetwork}

              if curl --silent --fail --insecure "https://${clusterAddr}/livez" --max-time 10 >/dev/null; then
                echo "Kubernetes API server is already running, skipping initialization of cluster."
                exit 0
              else
                echo "Initializing Kubernetes cluster..."

                ${mkApiServerCert}
                ${mkKubeletClientCert}
                ${mkFrontProxyClientCert}
                ${mkEtcdServerCert}
                ${mkEtcdPeerCert}
                ${mkEtcdHealthcheckClientCert}
                ${mkEtcdApiServerClientCert}

                ${mkKubeletKubeconfig}
                ${mkControllerManagerKubeconfig}
                ${mkSchedulerKubeconfig}

                mkdir -p /etc/kubernetes/manifests

              cat > /etc/kubernetes/manifests/etcd.yaml <<-EOF
              ${etcdManifest}
              EOF

                chmod 644 /etc/kubernetes/manifests/etcd.yaml

              cat > /etc/kubernetes/manifests/kube-apiserver.yaml <<-EOF
              ${apiServerManifest}
              EOF

                chmod 644 /etc/kubernetes/manifests/kube-apiserver.yaml

              cat > /etc/kubernetes/manifests/kube-controller-manager.yaml <<-EOF
              ${controllerManagerManifest}
              EOF

                chmod 644 /etc/kubernetes/manifests/kube-controller-manager.yaml

              cat > /etc/kubernetes/manifests/kube-scheduler.yaml <<-EOF
              ${schedulerManifest}
              EOF

                chmod 644 /etc/kubernetes/manifests/kube-scheduler.yaml
              fi
            '';
        };
      };

      # systemd.services = ({

      #   kubernetes-init-kubeconfig-admin = mkKubeconfigUnit {
      #     ca = "/etc/kubernetes/pki/ca";
      #     kubeconfig = "/etc/kubernetes/admin.conf";
      #     username = "kubernetes-admin";
      #     group = "kubeadm:cluster-admins";
      #     expirationDays = 365;
      #   };

      #   kubernetes-init-kubeconfig-super-admin = mkKubeconfigUnit {
      #     ca = "/etc/kubernetes/pki/ca";
      #     kubeconfig = "/etc/kubernetes/super-admin.conf";
      #     username = "kubernetes-super-admin";
      #     group = "system:masters";
      #     expirationDays = 365;
      #   };

      #   kubelet = {
      #     description = "Kubelet";
      #     documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
      #     after = [
      #       "crio.service"
      #       "kubernetes-init-control-plane.target"
      #     ];
      #     requires = [ "crio.service" ];
      #     wantedBy = [ "multi-user.target" ];

      #     serviceConfig = {
      #       ExecStart = ''
      #         ${pkgs.kubernetes}/bin/kubelet \
      #           --config=/etc/kubernetes/kubelet/config.yaml \
      #           --kubeconfig=/etc/kubernetes/kubelet.conf \
      #           --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
      #           --v=2
      #       '';
      #       Restart = "on-failure";
      #       RestartSec = "5";
      #     };
      #   };
      # });
    })
    (lib.mkIf (cfg.mode == "tailscale" && cfg.kind == "control-plane") {
      nebulis.tailscale = {
        tags = [
          "kubernetes-control-plane"
        ];

        services = {
          "${cfg.tailscaleApiServerSvc}" = {
            mode = "tcp";
            port = 443;
            target = "127.0.0.1:${toString cfg.apiServerPort}";
          };

          "${cfg.tailscaleEtcdSvc}" = {
            mode = "tcp";
            port = 443;
            target = "127.0.0.1:${toString cfg.etcdClientPort}";
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
      ];
    }
  ];
}

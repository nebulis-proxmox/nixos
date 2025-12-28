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

  initWhileLoop = ''
    until [ "${ipCommand}" != "null" ]; do
      echo "Waiting for valid IP address..."
      sleep 1
    done
  '';

  mkCertUnit =
    {
      ca,
      cert,
      subject,
      expirationDays,
      altNames ? { },
      wantedByUnits ? [ "kubernetes-init-certs.target" ],
    }:
    {
      path = [ pkgs.openssl ] ++ pathPackages;
      description = "Create ${cert}.crt Certificate";
      documentation = [ "https://kubernetes.io/docs" ];
      after = afterUnits;
      wantedBy = wantedByUnits;

      enableStrictShellChecks = true;
      script =
        let
          subjectString = lib.strings.concatStrings (
            lib.attrsets.mapAttrsToList (k: v: "/${k}=${v}") subject
          );
          subjectArg = if subjectString == "" then "" else "-subj \"${subjectString}\"";

          altNamesLine = builtins.concatStringsSep ", " (
            lib.attrsets.mapAttrsToList (
              kind: values: builtins.concatStringsSep ", " (map (v: "${kind}:${v}") values)
            ) altNames
          );

          altNamesExt = if altNamesLine == "" then "" else "subjectAltName = ${altNamesLine}";
          altNamesExtArg = if altNamesExt == "" then "" else "-addext \"${altNamesExt}\"";
          altNamesExtFileArg = if altNamesExt == "" then "" else "-extfile <(echo \"${altNamesExt}\")";
        in
        ''
          ${initWhileLoop}

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
    };

  mkKubeconfigUnit =
    {
      ca,
      kubeconfig,
      username,
      group ? "",
      expirationDays,
      wantedByUnits ? [ "kubernetes-init-kubeconfig.target" ],
    }:
    {
      path = [
        pkgs.openssl
        pkgs.jq
      ]
      ++ pathPackages;
      description = "Create ${kubeconfig} Kubeconfig";
      documentation = [ "https://kubernetes.io/docs" ];
      after = afterUnits;
      wantedBy = wantedByUnits;
      enableStrictShellChecks = true;

      script =
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
          ${initWhileLoop}

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
              --arg serverHost "${ipCommand}" \
              '{
                apiVersion: "v1",
                kind: "Config",
                clusters: [
                  {
                    name: "kubernetes",
                    cluster: {
                      "certificate-authority-data": $caData,
                      server: "https://" + $serverHost + ":6443"
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
    };
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
        "kubernetes/kubelet/config.yaml" = {
          text = ''
            apiVersion: kubelet.config.k8s.io/v1beta1
            authentication:
              anonymous:
                enabled: false
              webhook:
                cacheTTL: 0s
                enabled: true
              x509:
                clientCAFile: /etc/kubernetes/pki/ca.crt
            authorization:
              mode: Webhook
              webhook:
                cacheAuthorizedTTL: 0s
                cacheUnauthorizedTTL: 0s
            cgroupDriver: systemd
            clusterDNS:
            - 10.96.0.10
            clusterDomain: cluster.local
            containerRuntimeEndpoint: unix:///var/run/crio/crio.sock
            cpuManagerReconcilePeriod: 0s
            crashLoopBackOff: {}
            evictionPressureTransitionPeriod: 0s
            fileCheckFrequency: 0s
            healthzBindAddress: 127.0.0.1
            healthzPort: 10248
            httpCheckFrequency: 0s
            imageMaximumGCAge: 0s
            imageMinimumGCAge: 0s
            kind: KubeletConfiguration
            logging:
              flushFrequency: 0
              options:
                json:
                  infoBufferSize: "0"
                text:
                  infoBufferSize: "0"
              verbosity: 0
            memorySwap: {}
            nodeStatusReportFrequency: 0s
            nodeStatusUpdateFrequency: 0s
            rotateCertificates: true
            runtimeRequestTimeout: 0s
            shutdownGracePeriod: 0s
            shutdownGracePeriodCriticalPods: 0s
            staticPodPath: /etc/kubernetes/manifests
            streamingConnectionIdleTimeout: 0s
            syncFrequency: 0s
            volumeStatsAggPeriod: 0s
          '';
          mode = "0644";
        };
      };

      systemd.targets = {
        kubernetes-init-certs = {
          description = "Kubernetes Certificate generation";
          documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];
          wantedBy = [ "multi-user.target" ];
        };
        kubernetes-init-kubeconfig = {
          description = "Generate all kubeconfig files necessary to establish the control plane and the admin kubeconfig file";
          documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];
          after = [ "kubernetes-init-certs.target" ];
          wantedBy = [ "multi-user.target" ];
        };
        kubernetes-init-etcd = {
          description = "Generate static Pod manifest file for local etcd";
          documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];
          after = [ "kubernetes-init-kubeconfig.target" ];
          wantedBy = [ "multi-user.target" ];
        };
        kubernetes-init-control-plane = {
          description = "Generate all static Pod manifest files necessary to establish the control plane";
          documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];
          after = [ "kubernetes-init-etcd.target" ];
          wantedBy = [ "multi-user.target" ];
        };
      };

      systemd.services = ({
        kubernetes-init-certs-apiserver = mkCertUnit {
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
              config.networking.hostName
            ];
          };
          expirationDays = 365;
        };

        kubernetes-init-certs-apiserver-kubelet-client = mkCertUnit {
          ca = "/etc/kubernetes/pki/ca";
          cert = "/etc/kubernetes/pki/apiserver-kubelet-client";
          subject = {
            CN = "kube-apiserver-kubelet-client";
            O = "kubeadm:cluster-admins";
          };
          expirationDays = 365;
        };

        kubernetes-init-certs-frontproxy-client = mkCertUnit {
          ca = "kubernetes/pki/front-proxy-ca";
          cert = "/etc/kubernetes/pki/front-proxy-client";
          subject = {
            CN = "front-proxy-client";
          };
          expirationDays = 365;
        };

        kubernetes-init-certs-etcd-server = mkCertUnit {
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
              config.networking.hostName
              "localhost"
            ];
          };
          expirationDays = 365;
        };

        kubernetes-init-certs-etcd-peer = mkCertUnit {
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
              config.networking.hostName
              "localhost"
            ];
          };
          expirationDays = 365;
        };

        kubernetes-init-certs-etcd-healthcheck-client = mkCertUnit {
          ca = "/etc/kubernetes/pki/etcd/ca";
          cert = "/etc/kubernetes/pki/etcd/healthcheck-client";
          subject = {
            CN = "kube-etcd-healthcheck-client";
          };
          expirationDays = 365;
        };

        kubernetes-init-certs-apiserver-etcd-client = mkCertUnit {
          ca = "/etc/kubernetes/pki/etcd/ca";
          cert = "/etc/kubernetes/pki/apiserver-etcd-client";
          subject = {
            CN = "kube-apiserver-etcd-client";
          };
          expirationDays = 365;
        };

        kubernetes-init-certs-sa = {
          path = pathPackages ++ [ pkgs.openssl ];

          enableStrictShellChecks = true;
          description = "Create Service Account Key Pair";
          documentation = [ "https://kubernetes.io/docs" ];
          after = afterUnits;
          wantedBy = [ "kubernetes-init-certs.target" ];

          script = ''
            if [ ! -f /etc/kubernetes/pki/sa.key ]; then
              openssl genrsa -out "/etc/kubernetes/pki/sa.key" 4096
              openssl rsa -in "/etc/kubernetes/pki/sa.key" -pubout -out "/etc/kubernetes/pki/sa.pub"
              chmod 600 "/etc/kubernetes/pki/sa.key"
              chmod 644 "/etc/kubernetes/pki/sa.pub"
            fi
          '';
        };

        kubernetes-init-kubeconfig-admin = mkKubeconfigUnit {
          ca = "/etc/kubernetes/pki/ca";
          kubeconfig = "/etc/kubernetes/admin.conf";
          username = "kubernetes-admin";
          group = "kubeadm:cluster-admins";
          expirationDays = 365;
        };

        kubernetes-init-kubeconfig-super-admin = mkKubeconfigUnit {
          ca = "/etc/kubernetes/pki/ca";
          kubeconfig = "/etc/kubernetes/super-admin.conf";
          username = "kubernetes-super-admin";
          group = "system:masters";
          expirationDays = 365;
        };

        kubernetes-init-kubeconfig-bootstrap-kubelet = mkKubeconfigUnit {
          ca = "/etc/kubernetes/pki/ca";
          kubeconfig = "/etc/kubernetes/bootstrap-kubelet.conf";
          username = "system:node:${config.networking.hostName}";
          group = "system:nodes";
          expirationDays = 1;
        };

        kubernetes-init-kubeconfig-controller-manager = mkKubeconfigUnit {
          ca = "/etc/kubernetes/pki/ca";
          kubeconfig = "/etc/kubernetes/controller-manager.conf";
          username = "system:kube-controller-manager";
          expirationDays = 365;
        };

        kubernetes-init-kubeconfig-scheduler = mkKubeconfigUnit {
          ca = "/etc/kubernetes/pki/ca";
          kubeconfig = "/etc/kubernetes/scheduler.conf";
          username = "system:kube-scheduler";
          expirationDays = 365;
        };

        kubernetes-init-etcd-local = {
          path = pathPackages;
          enableStrictShellChecks = true;
          description = "Generate the static Pod manifest file for a local, single-node local etcd instance";
          documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];
          after = afterUnits;
          wantedBy = [ "kubernetes-init-etcd.target" ];

          serviceConfig = {
            Type = "oneshot";
          };

          script = ''
            ${initWhileLoop}

            if [ ! -f /etc/kubernetes/manifest/etcd.yaml ]; then
              mkdir -p /etc/kubernetes/manifests

            cat > /etc/kubernetes/manifests/etcd.yaml <<-EOF
            apiVersion: v1
            kind: Pod
            metadata:
              annotations:
                kubeadm.kubernetes.io/etcd.advertise-client-urls: https://${ipCommand}:2379
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
                - --advertise-client-urls=https://${ipCommand}:2379
                - --listen-client-urls=https://127.0.0.1:2379,https://${ipCommand}:2379
                - --initial-advertise-peer-urls=https://${ipCommand}:2380
                - --initial-cluster=${config.networking.hostName}=https://${ipCommand}:2380
                - --listen-metrics-urls=http://127.0.0.1:2381
                - --listen-peer-urls=https://${ipCommand}:2380
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
            EOF

              chmod 644 /etc/kubernetes/manifests/etcd.yaml
            fi
          '';
        };

        kubernetes-init-control-plane-apiserver = {
          path = pathPackages;
          enableStrictShellChecks = true;
          description = "Generates the kube-apiserver static Pod manifest";
          documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
          after = afterUnits;
          wantedBy = [ "kubernetes-init-control-plane.target" ];

          serviceConfig = {
            Type = "oneshot";
          };

          script = ''
            ${initWhileLoop}

            if [ ! -f /etc/kubernetes/manifest/kube-apiserver.yaml ]; then
              mkdir -p /etc/kubernetes/manifests

            cat > /etc/kubernetes/manifests/kube-apiserver.yaml <<-EOF
            apiVersion: v1
            kind: Pod
            metadata:
              annotations:
                kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: ${ipCommand}:6443
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
                - --etcd-servers=https://${ipCommand}:2379
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
                - --secure-port=6443
                - --service-account-issuer=https://kubernetes.default.svc.cluster.local
                - --service-account-key-file=/etc/kubernetes/pki/sa.pub
                - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
                - --service-cluster-ip-range=10.96.0.0/12
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
                - containerPort: 6443
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
            EOF

              chmod 644 /etc/kubernetes/manifests/kube-apiserver.yaml
            fi
          '';
        };

        kubernetes-init-control-plane-controller-manager = {
          path = pathPackages;

          enableStrictShellChecks = true;
          description = "Generates the kube-controller-manager static Pod manifest";
          documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];
          wantedBy = [ "kubernetes-init-control-plane.target" ];

          serviceConfig = {
            Type = "oneshot";
          };

          script = ''
            if [ ! -f /etc/kubernetes/manifest/kube-controller-manager.yaml ]; then
              mkdir -p /etc/kubernetes/manifests

            cat > /etc/kubernetes/manifests/kube-controller-manager.yaml <<-EOF
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
            EOF

              chmod 644 /etc/kubernetes/manifests/kube-controller-manager.yaml
            fi
          '';
        };

        kubernetes-init-control-plane-scheduler = {
          path = pathPackages;

          enableStrictShellChecks = true;
          description = "Generates the kube-scheduler static Pod manifest";
          documentation = [ "https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/" ];
          wantedBy = [ "kubernetes-init-control-plane.target" ];

          serviceConfig = {
            Type = "oneshot";
          };

          script = ''
            if [ ! -f /etc/kubernetes/manifest/kube-scheduler.yaml ]; then
              mkdir -p /etc/kubernetes/manifests

            cat > /etc/kubernetes/manifests/kube-scheduler.yaml <<-EOF
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
            EOF

              chmod 644 /etc/kubernetes/manifests/kube-scheduler.yaml
            fi
          '';
        };

        kubernetes-init-kubelet-start = {
          description = "Write kubelet settings and (re)start the kubelet";
          documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
          after = [
            "crio.service"
            "kubernetes-init-control-plane.target"
          ];
          requires = [ "crio.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = ''
              ${pkgs.kubernetes}/bin/kubelet \
                --config=/etc/kubernetes/kubelet/config.yaml \
                --kubeconfig=/etc/kubernetes/kubelet/bootstrap-kubelet.conf \
                --v=2
            '';
            Restart = "on-failure";
            RestartSec = "5";
          };
        };
      });
    })
    (lib.mkIf (cfg.mode == "tailscale") {
      nebulis.tailscale = {
        tags = [
          "kubernetes-control-plane"
        ];

        services.k8s = {
          mode = "tcp";
          port = 443;
          target = "127.0.0.1:6443";
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

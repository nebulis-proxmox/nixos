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

      systemd.services = (
        let
          afterUnits =
            if cfg.mode == "tailscale" then
              [ "tailscaled.service" ]
            else
              (if neworkingCfg.useBr0 then [ "network-addresses-br0.service" ] else [ ]);
          ipCommand =
            if cfg.mode == "tailscale" then
              "$(tailscale ip -4)"
            else
              # Ensure no IPv6 addresses are returned nor the loopback address
              "$(ip -json -br a | jq '[.[] | .addr_info[] | select(.prefixlen > 32 | not) | select(.local != \"127.0.0.1\") | .local][0]' -r)";
          initWhileLoop = ''
            until [ "${ipCommand}" != "null" ]; do
              echo "Waiting for valid IP address..."
              sleep 1
            done
          '';
          pathPackages =
            if cfg.mode == "tailscale" then
              [ tailscaleCfg.package ]
            else
              [
                pkgs.jq
                pkgs.iproute2
              ];
        in
        {
          create-etcd-manifest = {
            path = pathPackages;
            enableStrictShellChecks = true;
            description = "Create Etcd Manifest";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

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

          create-etcd-certs = {
            path = pathPackages ++ [ pkgs.openssl ];
            enableStrictShellChecks = true;
            description = "Create Etcd Certificates";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

              if [ ! -f /etc/kubernetes/pki/etcd/ca.crt ] || [ ! -f /etc/kubernetes/pki/etcd/ca.key ]; then
                echo "Required Etcd CA is missing, cannot create Etcd certs."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/pki/etcd/server.key ]; then
                openssl genpkey -algorithm ED25519 -out "/etc/kubernetes/pki/etcd/server.key"
                chmod 600 "/etc/kubernetes/pki/etcd/server.key"
              fi

              if [ ! -f /etc/kubernetes/pki/etcd/server.crt ] || ! openssl x509 -checkend 86400 -noout -in /etc/kubernetes/pki/etcd/server.crt; then
                openssl req -new \
                  -key "/etc/kubernetes/pki/etcd/server.key" \
                  -subj "/CN=kube-etcd/O=etcd" \
                  -out "/tmp/etcd-server.csr" \
                  -addext "subjectAltName = DNS:${config.networking.hostName}, IP:${ipCommand}, DNS:localhost, IP:127.0.0.1"

                openssl x509 -req \
                  -in "/tmp/etcd-server.csr" \
                  -CA "/etc/kubernetes/pki/etcd/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/etcd/ca.key" \
                  -out "/etc/kubernetes/pki/etcd/server.crt" \
                  -days 365 \
                  -sha512 \
                  -extfile <(printf "subjectAltName=DNS:${config.networking.hostName}, IP:%s, DNS:localhost, IP:127.0.0.1" "${ipCommand}")
                chmod 644 "/etc/kubernetes/pki/etcd/server.crt"
                rm -f "/tmp/etcd-server.csr"
              fi

              if [ ! -f /etc/kubernetes/pki/etcd/peer.key ]; then
                openssl genpkey -algorithm ED25519 -out "/etc/kubernetes/pki/etcd/peer.key"
                chmod 600 "/etc/kubernetes/pki/etcd/peer.key"
              fi

              if [ ! -f /etc/kubernetes/pki/etcd/peer.crt ] || ! openssl x509 -checkend 86400 -noout -in /etc/kubernetes/pki/etcd/peer.crt; then
                openssl req -new \
                  -key "/etc/kubernetes/pki/etcd/peer.key" \
                  -subj "/CN=kube-etcd-peer/O=etcd" \
                  -out "/tmp/etcd-peer.csr" \
                  -addext "subjectAltName = DNS:${config.networking.hostName}, IP:${ipCommand}, DNS:localhost, IP:127.0.0.1"

                openssl x509 -req \
                  -in "/tmp/etcd-peer.csr" \
                  -CA "/etc/kubernetes/pki/etcd/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/etcd/ca.key" \
                  -out "/etc/kubernetes/pki/etcd/peer.crt" \
                  -days 365 \
                  -sha512 \
                  -extfile <(printf "subjectAltName=DNS:${config.networking.hostName}, IP:%s, DNS:localhost, IP:127.0.0.1" "${ipCommand}")
                chmod 644 "/etc/kubernetes/pki/etcd/peer.crt"
                rm -f "/tmp/etcd-peer.csr"
              fi

              if [ ! -f /etc/kubernetes/pki/apiserver-etcd-client.key ]; then
                openssl genpkey -algorithm ED25519 -out "/etc/kubernetes/pki/apiserver-etcd-client.key"
                chmod 600 "/etc/kubernetes/pki/apiserver-etcd-client.key"
              fi

              if [ ! -f /etc/kubernetes/pki/apiserver-etcd-client.crt ] || ! openssl x509 -checkend 86400 -noout -in /etc/kubernetes/pki/apiserver-etcd-client.crt; then
                openssl req -new \
                  -key "/etc/kubernetes/pki/apiserver-etcd-client.key" \
                  -subj "/CN=kube-apiserver-etcd-client" \
                  -out "/tmp/apiserver-etcd-client.csr"

                openssl x509 -req \
                  -in "/tmp/apiserver-etcd-client.csr" \
                  -CA "/etc/kubernetes/pki/etcd/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/etcd/ca.key" \
                  -out /etc/kubernetes/pki/apiserver-etcd-client.crt \
                  -days 365 \
                  -sha512
                chmod 644 /etc/kubernetes/pki/apiserver-etcd-client.crt
                rm -f "/tmp/apiserver-etcd-client.csr"
              fi
            '';
          };

          create-apiserver-manifest = {
            path = pathPackages;

            enableStrictShellChecks = true;
            description = "Create Kube API Server Manifest";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

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

                chmod 644 /etc/kubernetes/manifests/etcd.yaml
              fi
            '';
          };

          create-apiserver-certs = {
            path = pathPackages ++ [ pkgs.openssl ];

            enableStrictShellChecks = true;
            description = "Create API Server Certs";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

            script = ''
              ${initWhileLoop}

              if [ ! -f /etc/kubernetes/pki/ca.crt ] || [ ! -f /etc/kubernetes/pki/ca.key ]; then
                echo "Required certs are missing, cannot create kubelet client certificates."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/pki/apiserver.key ]; then
                openssl genpkey -algorithm ED25519 -out "/etc/kubernetes/pki/apiserver.key"
                chmod 600 "/etc/kubernetes/pki/apiserver.key"
              fi

              if [ ! -f /etc/kubernetes/pki/apiserver.crt ] || ! openssl x509 -checkend 86400 -noout -in /etc/kubernetes/pki/apiserver.crt; then
                openssl req -new \
                  -key "/etc/kubernetes/pki/apiserver.key" \
                  -subj "/CN=kube-apiserver/O=kube-apiserver" \
                  -out "/tmp/apiserver.csr" \
                  -addext "subjectAltName = DNS:${config.networking.hostName}, IP:${ipCommand}"

                openssl x509 -req \
                  -in "/tmp/apiserver.csr" \
                  -CA "/etc/kubernetes/pki/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/ca.key" \
                  -out "/etc/kubernetes/pki/apiserver.crt" \
                  -days 365 \
                  -sha512 \
                  -extfile <(printf "subjectAltName=DNS:%s,IP:%s" "${config.networking.hostName}" "${ipCommand}")
                chmod 644 "/etc/kubernetes/pki/apiserver.crt"
                rm -f "/tmp/apiserver.csr"
              fi

              if [ ! -f /etc/kubernetes/pki/apiserver-kubelet-client.key ]; then
                openssl genpkey -algorithm ED25519 -out "/etc/kubernetes/pki/apiserver-kubelet-client.key"
                chmod 600 "/etc/kubernetes/pki/apiserver-kubelet-client.key"
              fi

              if [ ! -f /etc/kubernetes/pki/apiserver-kubelet-client.crt ] || ! openssl x509 -checkend 86400 -noout -in /etc/kubernetes/pki/apiserver-kubelet-client.crt; then
                openssl req -new \
                  -key "/etc/kubernetes/pki/apiserver-kubelet-client.key" \
                  -subj "/CN=kube-apiserver-kubelet-client/O=system:masters" \
                  -out "/tmp/apiserver-kubelet-client.csr"

                openssl x509 -req \
                  -in "/tmp/apiserver-kubelet-client.csr" \
                  -CA "/etc/kubernetes/pki/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/ca.key" \
                  -out "/etc/kubernetes/pki/apiserver-kubelet-client.crt" \
                  -days 365 \
                  -sha512

                chmod 644 "/etc/kubernetes/pki/apiserver-kubelet-client.crt"
                rm -f "/tmp/apiserver-kubelet-client.csr"
              fi

              if [ ! -f /etc/kubernetes/pki/front-proxy-ca.crt ] || [ ! -f /etc/kubernetes/pki/front-proxy-ca.key ]; then
                echo "Required certs are missing, cannot create kubelet client certificates."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/pki/front-proxy-client.key ]; then
                openssl genpkey -algorithm ED25519 -out "/etc/kubernetes/pki/front-proxy-client.key"
                chmod 600 "/etc/kubernetes/pki/front-proxy-client.key"
              fi

              if [ ! -f /etc/kubernetes/pki/front-proxy-client.crt ] || ! openssl x509 -checkend 86400 -noout -in /etc/kubernetes/pki/front-proxy-client.crt; then
                openssl req -new \
                  -key "/etc/kubernetes/pki/front-proxy-client.key" \
                  -subj "/CN=front-proxy-client/O=front-proxy" \
                  -out "/tmp/front-proxy-client.csr"

                openssl x509 -req \
                  -in "/tmp/front-proxy-client.csr" \
                  -CA "/etc/kubernetes/pki/front-proxy-ca.crt" \
                  -CAkey "/etc/kubernetes/pki/front-proxy-ca.key" \
                  -out "/etc/kubernetes/pki/front-proxy-client.crt" \
                  -days 365 \
                  -sha512

                chmod 644 "/etc/kubernetes/pki/front-proxy-client.crt"
                rm -f "/tmp/front-proxy-client.csr"
              fi

              if [ ! -f /etc/kubernetes/pki/sa.key ]; then
                openssl genrsa -out "/etc/kubernetes/pki/sa.key" 4096
                openssl rsa -in "/etc/kubernetes/pki/sa.key" -pubout -out "/etc/kubernetes/pki/sa.pub"
                chmod 600 "/etc/kubernetes/pki/sa.key"
                chmod 644 "/etc/kubernetes/pki/sa.pub"
              fi
            '';
          };

          create-kube-controller-manager-manifest = {
            path = pathPackages;

            enableStrictShellChecks = true;
            description = "Create Kube Controller Manager Manifest";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

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

          create-controller-manager-kubeconfig = {
            path = pathPackages ++ [ pkgs.openssl ];

            enableStrictShellChecks = true;
            description = "Create Controller Manager kubeconfig";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

              if [ ! -f /etc/kubernetes/pki/ca.crt ] || [ ! -f /etc/kubernetes/pki/ca.key ]; then
                echo "Required certs are missing, cannot create controller manager kubeconfig."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/controller-manager.conf ]; then
                openssl genpkey -algorithm ED25519 -out "/tmp/controller-manager.key"

                openssl req -new \
                  -key "/tmp/controller-manager.key" \
                  -subj "/CN=system:kube-controller-manager" \
                  -out "/tmp/controller-manager.csr"

                openssl x509 -req \
                  -in "/tmp/controller-manager.csr" \
                  -CA "/etc/kubernetes/pki/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/ca.key" \
                  -out "/tmp/controller-manager.crt" \
                  -days 365 \
                  -sha512

              cat > /etc/kubernetes/controller-manager.conf <<-EOF
              apiVersion: v1
              kind: Config
              clusters:
              - name: kubernetes
                cluster:
                  certificate-authority-data: $(base64 -w0 /etc/kubernetes/pki/ca.crt)
                  server: https://${ipCommand}:6443
              contexts:
              - name: system:kube-controller-manager@kubernetes
                context:
                  cluster: kubernetes
                  user: system:kube-controller-manager
              current-context: system:kube-controller-manager@kubernetes
              users:
              - name: system:kube-controller-manager
                user:
                  client-certificate-data: $(base64 -w0 /tmp/controller-manager.crt)
                  client-key-data: $(base64 -w0 /tmp/controller-manager.key)
              EOF

                rm -f "/tmp/controller-manager.key" "/tmp/controller-manager.csr" "/tmp/controller-manager.crt"
                
                chmod 600 "/etc/kubernetes/controller-manager.conf"
              fi
            '';
          };

          create-scheduler-manifest = {
            path = pathPackages;

            enableStrictShellChecks = true;
            description = "Create Kube Scheduler Manifest";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

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

          create-scheduler-kubeconfig = {
            path = pathPackages ++ [ pkgs.openssl ];

            enableStrictShellChecks = true;
            description = "Create Scheduler kubeconfig";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

              if [ ! -f /etc/kubernetes/pki/ca.crt ] || [ ! -f /etc/kubernetes/pki/ca.key ]; then
                echo "Required certs are missing, cannot create scheduler kubeconfig."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/scheduler.conf ]; then
                openssl genpkey -algorithm ED25519 -out "/tmp/scheduler.key"

                openssl req -new \
                  -key "/tmp/scheduler.key" \
                  -subj "/CN=system:kube-scheduler" \
                  -out "/tmp/scheduler.csr"

                openssl x509 -req \
                  -in "/tmp/scheduler.csr" \
                  -CA "/etc/kubernetes/pki/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/ca.key" \
                  -out "/tmp/scheduler.crt" \
                  -days 365 \
                  -sha512

              cat > /etc/kubernetes/scheduler.conf <<-EOF
              apiVersion: v1
              kind: Config
              clusters:
              - name: kubernetes
                cluster:
                  certificate-authority-data: $(base64 -w0 /etc/kubernetes/pki/ca.crt)
                  server: https://${ipCommand}:6443
              contexts:
              - name: system:kube-scheduler@kubernetes
                context:
                  cluster: kubernetes
                  user: system:kube-scheduler
              current-context: system:kube-scheduler@kubernetes
              users:
              - name: system:kube-scheduler
                user:
                  client-certificate-data: $(base64 -w0 /tmp/scheduler.crt)
                  client-key-data: $(base64 -w0 /tmp/scheduler.key)
              EOF

                rm -f "/tmp/scheduler.key" "/tmp/scheduler.csr" "/tmp/scheduler.crt"

                chmod 600 "/etc/kubernetes/scheduler.conf"
              fi
            '';
          };

          create-kubelet-kubeconfig = {
            path = pathPackages ++ [ pkgs.openssl ];

            enableStrictShellChecks = true;
            description = "Create Kubelet kubeconfig";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            before = [ "kubelet.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

              if [ ! -f /etc/kubernetes/pki/ca.crt ] || [ ! -f /etc/kubernetes/pki/ca.key ]; then
                echo "Required certs are missing, cannot create kubelet kubeconfig."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/kubelet/kubeconfig ]; then
                openssl genpkey -algorithm ED25519 -out "/tmp/kubelet.key"

                openssl req -new \
                  -key "/tmp/kubelet.key" \
                  -subj "/CN=system:node:${config.networking.hostName}/O=system:nodes" \
                  -out "/tmp/kubelet.csr"

                openssl x509 -req \
                  -in "/tmp/kubelet.csr" \
                  -CA "/etc/kubernetes/pki/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/ca.key" \
                  -out "/tmp/kubelet.crt" \
                  -days 365 \
                  -sha512

              cat > /etc/kubernetes/kubelet/kubeconfig <<-EOF
              apiVersion: v1
              kind: Config
              clusters:
              - name: kubernetes
                cluster:
                  certificate-authority-data: $(base64 -w0 /etc/kubernetes/pki/ca.crt)
                  server: https://${ipCommand}:6443
              contexts:
              - name: system:node:${config.networking.hostName}@kubernetes
                context:
                  cluster: kubernetes
                  user: system:node:${config.networking.hostName}
              current-context: system:node:${config.networking.hostName}@kubernetes
              users:
              - name: system:node:${config.networking.hostName}
                user:
                  client-certificate-data: $(base64 -w0 /tmp/kubelet.crt)
                  client-key-data: $(base64 -w0 /tmp/kubelet.key)
              EOF

                rm -f "/tmp/kubelet.key" "/tmp/kubelet.csr" "/tmp/kubelet.crt"
                
                chmod 600 "/etc/kubernetes/kubelet/kubeconfig"
              fi
            '';
          };

          kubelet = {
            description = "Kubernetes Kubelet";
            documentation = [ "https://github.com/kubernetes/kubernetes" ];
            after = [ "crio.service" ];
            requires = [ "crio.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              ExecStart = ''
                ${pkgs.kubernetes}/bin/kubelet \
                  --config=/etc/kubernetes/kubelet/config.yaml \
                  --kubeconfig=/etc/kubernetes/kubelet/kubeconfig \
                  --v=2
              '';
              Restart = "on-failure";
              RestartSec = "5";
            };
          };

          create-super-admin-kubeconfig = {
            path = pathPackages ++ [ pkgs.openssl ];

            enableStrictShellChecks = true;
            description = "Create Super Admin kubeconfig";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

              if [ ! -f /etc/kubernetes/pki/ca.crt ] || [ ! -f /etc/kubernetes/pki/ca.key ]; then
                echo "Required certs are missing, cannot create super admin kubeconfig."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/super-admin.conf ]; then
                openssl genpkey -algorithm ED25519 -out "/tmp/super-admin.key"

                openssl req -new \
                  -key "/tmp/super-admin.key" \
                  -subj "/CN=kubernetes-super-admin/O=system:masters" \
                  -out "/tmp/super-admin.csr"

                openssl x509 -req \
                  -in "/tmp/super-admin.csr" \
                  -CA "/etc/kubernetes/pki/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/ca.key" \
                  -out "/tmp/super-admin.crt" \
                  -days 365 \
                  -sha512

              cat > /etc/kubernetes/super-admin.conf <<-EOF
              apiVersion: v1
              kind: Config
              clusters:
              - name: kubernetes
                cluster:
                  certificate-authority-data: $(base64 -w0 /etc/kubernetes/pki/ca.crt)
                  server: https://${ipCommand}:6443
              contexts:
              - name: kubernetes-super-admin@kubernetes
                context:
                  cluster: kubernetes
                  user: kubernetes-super-admin
              current-context: kubernetes-super-admin@kubernetes
              users:
              - name: kubernetes-super-admin
                user:
                  client-certificate-data: $(base64 -w0 /tmp/super-admin.crt)
                  client-key-data: $(base64 -w0 /tmp/super-admin.key)
              EOF

                rm -f "/tmp/super-admin.key" "/tmp/super-admin.csr" "/tmp/super-admin.crt"

                chmod 600 "/etc/kubernetes/super-admin.conf"
              fi
            '';
          };

          create-admin-kubeconfig = {
            path = pathPackages ++ [ pkgs.openssl ];

            enableStrictShellChecks = true;
            description = "Create Admin kubeconfig";
            documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
            after = afterUnits;
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
            };

            script = ''
              ${initWhileLoop}

              if [ ! -f /etc/kubernetes/pki/ca.crt ] || [ ! -f /etc/kubernetes/pki/ca.key ]; then
                echo "Required certs are missing, cannot create admin kubeconfig."
                exit 1
              fi

              if [ ! -f /etc/kubernetes/admin.conf ]; then
                openssl genpkey -algorithm ED25519 -out "/tmp/admin.key"

                openssl req -new \
                  -key "/tmp/admin.key" \
                  -subj "/CN=kubernetes-admin/O=kubeadm:cluster-admins" \
                  -out "/tmp/admin.csr"

                openssl x509 -req \
                  -in "/tmp/admin.csr" \
                  -CA "/etc/kubernetes/pki/ca.crt" \
                  -CAkey "/etc/kubernetes/pki/ca.key" \
                  -out "/tmp/admin.crt" \
                  -days 365 \
                  -sha512

              cat > /etc/kubernetes/admin.conf <<-EOF
              apiVersion: v1
              kind: Config
              clusters:
              - name: kubernetes
                cluster:
                  certificate-authority-data: $(base64 -w0 /etc/kubernetes/pki/ca.crt)
                  server: https://${ipCommand}:6443
              contexts:
              - name: kubernetes-admin@kubernetes
                context:
                  cluster: kubernetes
                  user: kubernetes-admin
              current-context: kubernetes-admin@kubernetes
              users:
              - name: kubernetes-admin
                user:
                  client-certificate-data: $(base64 -w0 /tmp/admin.crt)
                  client-key-data: $(base64 -w0 /tmp/admin.key)
              EOF

                rm -f "/tmp/admin.key" "/tmp/admin.csr" "/tmp/admin.crt"

                chmod 600 "/etc/kubernetes/admin.conf"
              fi
            '';
          };
        }
      );
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

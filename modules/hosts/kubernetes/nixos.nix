{
  config,
  pkgs,
  lib,
  inputs,
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
        };
        "kubernetes/pki/ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-kubernetes.crt";
          mode = "0644";
        };
        "kubernetes/pki/front-proxy-ca.key" = {
          source = config.age.secrets."ca-kubernetes-front-proxy.key".path;
        };
        "kubernetes/pki/front-proxy-ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-kubernetes-front-proxy.crt";
          mode = "0644";
        };
        "kubernetes/pki/etcd/ca.key" = {
          source = config.age.secrets."ca-etcd.key".path;
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

      systemd.services = {
        create-apiserver-kubelet-config = {
          path = [
            pkgs.openssl
          ];

          enableStrictShellChecks = true;
          description = "Create Kubelet Configuration for API Server";
          documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
          before = [ "kubelet.service" ];
          wantedBy = [ "multi-user.target" ];

          script = ''
            if [ ! -f /etc/kubernetes/pki/ca.crt ] || [ ! -f /etc/kubernetes/pki/ca.key ]; then
              echo "Required certs are missing, cannot create kubelet client certificates."
              exit 1
            fi

            if [ ! -f /etc/kubernetes/pki/apiserver-kubelet-client.key ]; then
              openssl genpkey -algorithm ED25519 -out "/etc/kubernetes/pki/apiserver-kubelet-client.key"
              chmod 600 "/etc/kubernetes/pki/apiserver-kubelet-client.key"
            fi

            if [ ! -f /etc/kubernetes/pki/apiserver-kubelet-client.crt ] || ! openssl x509 -checkend 86400 -noout -in /etc/kubernetes/pki/apiserver-kubelet-client.crt; then
              openssl req -new \
                -key "/etc/kubernetes/pki/apiserver-kubelet-client.key" \
                -subj "/CN=kube-apiserver-kubelet-client/O=kubeadm:cluster-admins" \
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
          '';
        };

        create-kubelet-kubeconfig = {
          path = [
            pkgs.openssl
          ];

          enableStrictShellChecks = true;
          description = "Create Kubelet kubeconfig";
          documentation = [ "https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/" ];
          before = [ "kubelet.service" ];
          wantedBy = [ "multi-user.target" ];

          script = ''
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
                server: https://127.0.0.1:6443
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
      };

      nebulis.tailscale = {
        tags = [
          "kubernetes-control-plane"
        ];

        services.k8s = {
          mode = "tcp";
          port = 443;
          target = "127.0.0.1:8080";
        };
      };
    })
  ];
}

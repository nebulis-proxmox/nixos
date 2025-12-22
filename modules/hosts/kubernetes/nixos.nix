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
        "kubernetes/kubelet-config.yaml" = {
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

      systemd.services.kubelet = {
        description = "Kubernetes Kubelet";
        documentation = [ "https://github.com/kubernetes/kubernetes" ];
        after = [ "crio.service" ];
        requires = [ "crio.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          ExecStart = ''
            ${pkgs.kubernetes}/bin/kubelet \
              --config=/etc/kubernetes/kubelet-config.yaml \
              --v=2
          '';
          Restart = "on-failure";
          RestartSec = "5";
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

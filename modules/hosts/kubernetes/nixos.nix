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
      };

      environment.etc = {
        "kubernetes/ca.key" = {
          source = config.age.secrets."ca-kubernetes.key".path;
        };
        "kubernetes/ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-kubernetes.crt";
          mode = "0644";
        };
        "kubernetes/etcd/ca.key" = {
          source = config.age.secrets."ca-etcd.key".path;
        };
        "kubernetes/etcd/ca.crt" = {
          text = builtins.readFile "${inputs.self}/certs/ca-etcd.crt";
          mode = "0644";
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

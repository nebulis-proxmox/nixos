{
  lib,
  ...
}:
{
  options.nebulis.kubernetes = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        enable kubernetes host module
      '';
    };
    kind = lib.mkOption {
      type = lib.types.enum [
        "control-plane"
        "worker"
      ];
      default = "control-plane";
      description = ''
        kind of kubernetes node
      '';
    };
    mode = lib.mkOption {
      type = lib.types.enum [
        "lan"
        "tailscale"
      ];
      default = "lan";
      description = ''
        networking mode for kubernetes cluster communication
      '';
    };
    apiServerHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        hostname for kubernetes api server
      '';
    };
    clusterIpRange = lib.mkOption {
      type = lib.types.str;
      default = "10.96.0.0/12";
      description = ''
        cluster ip range for kubernetes services
      '';
    };
    apiServerPort = lib.mkOption {
      type = lib.types.int;
      default = 6443;
      description = ''
        port for kubernetes api server
      '';
    };
    etcdClientHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        hostname for etcd client communication
      '';
    };
    etcdPeerPort = lib.mkOption {
      type = lib.types.int;
      default = 2380;
      description = ''
        port for etcd peer communication
      '';
    };
    etcdClientPort = lib.mkOption {
      type = lib.types.int;
      default = 2379;
      description = ''
        port for etcd client communication
      '';
    };
  };
}

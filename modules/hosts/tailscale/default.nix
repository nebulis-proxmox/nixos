{
  options,
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

with lib;
let
  cfg = config.nebulis.tailscale;
in
{
  options.nebulis.tailscale = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        enable custom tailscale module
      '';
    };
    package = mkOption {
      type = types.package;
      default = pkgs.unstable.tailscale;
      description = ''
        Tailscale package to use
      '';
    };
    enableSsh = mkOption {
      type = types.bool;
      default = true;
      description = ''
        enable tailscale ssh
      '';
    };
    acceptDns = mkOption {
      type = types.bool;
      default = true;
      description = ''
        enable tailscale dns acceptance
      '';
    };
    resetCredentials = mkOption {
      type = types.bool;
      default = true;
      description = ''
        reset tailscale credentials on start
      '';
    };
    extraUpFlags = mkOption {
      type = types.listOf types.str;
      default = [
      ];
      description = ''
        Extra flags to pass to tailscale up.
      '';
    };
    tags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Tags to advertise to the tailnet.
      '';
    };
    useRoutingFeatures = mkOption {
      type = types.enum [
        "none"
        "client"
        "server"
        "both"
      ];
      default = "none";
      example = "server";
      description = lib.mdDoc ''
        Enables settings required for Tailscale's routing features like subnet routers and exit nodes.

        To use these these features, you will still need to call `sudo tailscale up` with the relevant flags like `--advertise-exit-node` and `--exit-node`.

        When set to `client` or `both`, reverse path filtering will be set to loose instead of strict.
        When set to `server` or `both`, IP forwarding will be enabled.
      '';
    };
    tailnetName = mkOption {
      type = types.str;
      default = "";
      description = ''
        The name of the tailnet
      '';
    };
    authKeyFile = mkOption {
      type = types.nullOr types.path;
      default = "${config.age.secrets.tailscaleKey.path}";
      description = ''
        allow you to specify a key, or set null to disable
      '';
    };
    preApprovedSshAuthkey = mkOption {
      type = types.bool;
      default = false;
      description = ''
        decrypt pre-approved ssh authkey
      '';
    };

    services = mkOption {
      description = ''
        Submodule for configuring tailscale services
      '';
      default = { };
      type = types.attrsOf (
        types.submodule (
          { config, ... }:
          {
            options = {
              mode = mkOption {
                type = types.enum [
                  "http"
                  "https"
                  "tcp"
                  "tls-terminated-tcp"
                ];
                default = "https";
                description = ''
                  Mode of the tailscale service
                '';
              };
              port = mkOption {
                type = types.int;
                default = 443;
                description = ''
                  External port of the tailscale service
                '';
              };
              target = mkOption {
                type = types.str;
                description = ''
                  Target of the tailscale service
                '';
              };
            };
          }
        )
      );
    };
  };
}

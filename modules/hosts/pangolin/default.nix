{
  lib,
  config,
  ...
}:
{
  options.nebulis.pangolin = {
    newt = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          enable newt site
        '';
      };

      id = lib.mkOption {
        type = lib.types.str;
        description = ''
          Newt ID for pangolin
        '';
      };

      secretFileName = lib.mkOption {
        type = lib.types.str;
        default = "${config.networking.hostName}.newt.env.age";
        description = ''
          Newt Secret File name for pangolin
        '';
      };

      endpoint = lib.mkOption {
        type = lib.types.str;
        description = ''
          Endpoint for pangolin
        '';
      };
    };
  };
}

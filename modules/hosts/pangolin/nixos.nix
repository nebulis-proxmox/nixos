{
  inputs,
  config,
  lib,
  ...
}:
let
  cfg = config.nebulis.pangolin;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.newt.enable {
      age.secrets = {
        "newt.secret".file = inputs.self + "/secrets/" + cfg.newt.secretFileName;
      };

      services.newt = {
        enable = true;
        settings = {
          id = cfg.newt.id;
          endpoint = cfg.newt.endpoint;
        };
        environmentFile = config.age.secrets."newt.secret".path;
      };
    })
  ];
}

{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nebulis.kubernetes;
in
{
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
        kubernetes
      ];
    })
  ];
}

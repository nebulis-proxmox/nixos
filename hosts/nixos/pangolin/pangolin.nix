{
  lib,
  inputs,
  ...
}:
{
  imports = [
    # import custom modules
    inputs.self.nixosModules.nebulis
  ];
  config = {
    networking.hostName = "pangolin";
    system.stateVersion = "26.05";

    nebulis = {
      autoUpgrade.enable = true;
    };
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:
let
  USER = "nwmqpa";
  listOfUsers = config.inventory.hosts."${config.networking.hostName}".users.enableUsers;
in
{
  nebulis.users.users."${USER}" = {
    isRoot = true;
    hasNixosPassword = true;
    authSshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDdnrldIg416flniTapS18pv/IRwy6y03D+QmjF9euv"
    ];
    nixpkgs = {
      common = with pkgs; [
        vim
      ];
      nixos = with pkgs; [
      ];
    };
    homebrew = { };
  };
  home-manager.users."${USER}" = lib.mkIf (lib.elem USER listOfUsers) {
    nebulis = {
      shared.basic.enable = true;
    };
    programs = {
    };
  };
}

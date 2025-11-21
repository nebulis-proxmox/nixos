{
  config,
  lib,
  pkgs,
  ...
}:
let
  USER = "admin";
  listOfUsers = config.inventory.hosts."${config.networking.hostName}".users.enableUsers;
in
{
  nebulis.users.users."${USER}" = {
    isRoot = true;
    hasNixosPassword = true;
    authSshKeys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCyuLGDtfxmVmWpwew0cPOIZspwGUN5PF3Si8+PDqc6EjOMxVs5N57hi3mTZsYsZWJlLyHWyKd8m6Vf0r/Rc3CHJj5mwrQlIUtstkx2udT0/77zRt7GDHyLomsT3Ww7GBcZSXelxhVSd5Vb6hW9MBbQExIARzzgWmO+tvEbKJ2EjUpJFfA9jKivp9tnOaChwCaodljFQghxyjNgk550COV1u6t3mZE/vp66FXEwDjhFrJOedZ3tn8CNlmpa417mhEZZU9L7iecGHUzvaTEMzsYIx5GzsLAztq2t2OFBQpRZhTwNtisaUE+8v7Us39ReTEo/Een4sQJSAjpTpHy6fJi3"
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

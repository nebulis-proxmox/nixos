{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  listOfUsers = config.inventory.hosts."${config.networking.hostName}".users.enableUsers;
  rootSshKeys = config.inventory.hosts."${config.networking.hostName}".rootSshKeys;
in
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    inputs.self.users.nebulis
  ];
  config = lib.mkMerge [
    (lib.mkIf (rootSshKeys != [ ]) {
      users.users.root.openssh.authorizedKeys.keys = rootSshKeys;
    })
    (lib.mkIf (listOfUsers != [ ]) {

      users.mutableUsers = false;
      users.allowNoPasswordLogin = true;

      age.secrets = lib.listToAttrs (
        map
          (username: {
            name = "${username}Password";
            value = {
              file = (inputs.self + "/secrets/${username}Password.age");
            };
          })
          (builtins.filter (username: (config.nebulis.users.users.${username}.hasNixosPassword)) listOfUsers)
      );

      users.users = lib.listToAttrs (
        map (username: {
          name = username;
          value = {
            shell = pkgs.fish; # TODO: Option for different users
            isNormalUser = true;
            description = username;
            hashedPassword = lib.mkIf config.nebulis.users.users.${username}.hasNixosPassword null;
            hashedPasswordFile =
              lib.mkIf config.nebulis.users.users.${username}.hasNixosPassword
                config.age.secrets."${username}Password".path;
            openssh.authorizedKeys.keys = config.nebulis.users.users.${username}.authSshKeys;
            extraGroups = (if config.nebulis.users.users.${username}.isRoot then [ "wheel" ] else [ ]) ++ [
              "networkmanager"
            ];
            packages = with pkgs; [ ];
          };
        }) listOfUsers
      );

      environment.persistence."${config.nebulis.impermanence.dontBackup}" = {
        users = lib.listToAttrs (
          map (username: {
            name = username;
            value = {
              directories = [
                "nix"
                "documents"
                ".var"
                ".config"
                ".local"
              ];
              files = [ ];
            };
          }) listOfUsers
        );
      };

      security.sudo.extraRules =
        let
          passwordlessAdmins = lib.filter (
            username:
            config.nebulis.users.users.${username}.isRoot
            && !config.nebulis.users.users.${username}.hasNixosPassword
          ) listOfUsers;
        in
        lib.mkIf (passwordlessAdmins != [ ]) [
          {
            users = passwordlessAdmins;
            commands = [
              {
                command = "ALL";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];

      nix.settings.trusted-users =
        let
          rootUsers = builtins.filter (username: config.nebulis.users.users.${username}.isRoot) listOfUsers;
        in
        [ "root" ] ++ rootUsers;

      home-manager = {
        extraSpecialArgs = {
          inherit inputs;
        };
        users = lib.listToAttrs (
          map (username: {
            name = username;
            value = {
              imports = [ inputs.self.homeManagerModules.nebulis ];
              config.home.stateVersion = config.system.stateVersion;
              config.home.packages =
                config.nebulis.users.users.${username}.nixpkgs.nixos
                ++ config.nebulis.users.users.${username}.nixpkgs.common;
            };
          }) listOfUsers
        );
      };
    })
  ];
}

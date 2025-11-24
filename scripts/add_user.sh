#!/bin/bash

rootdir=$(git rev-parse --show-toplevel)

username=$(nix run $rootdir/utils/gum -- input --placeholder "new_user" --header "New user name:" --header.foreground="99" --prompt.foreground="212")

previous_users=$(ls users)

if echo "$previous_users" | grep -q "^$username$"; then
    echo -e "$(tput setaf 208)User $(tput setaf 212)$username$(tput setaf 208) already exists in users. Exiting.$(tput sgr0)"
    exit 1
fi

echo -e "$(tput setaf 99)Adding new user: $(tput setaf 212)$username$(tput sgr0)"

identities=$(cat $rootdir/secrets/secrets.nix | sed -nr 's/[[:space:]]+(.*)[[:space:]]+=[[:space:]]".*";/\1/p')

chosen_identities=$(nix run $rootdir/utils/gum -- choose --header "Select identities for user $username:" $identities "Not listed here" --no-limit)

if echo "$chosen_identities" | grep -q "Not listed here"; then
    echo -e "$(tput setaf 208)Adding new identity for user $(tput setaf 212)$username$(tput setaf 208).$(tput sgr0)"

    $rootdir/scripts/add_identity.sh

    identities=$(cat $rootdir/secrets/secrets.nix | sed -nr 's/[[:space:]]+(.*)[[:space:]]+=[[:space:]]".*";/\1/p')

    chosen_identities=$(nix run $rootdir/utils/gum -- choose --header "Select identities for user $username:" $identities --no-limit)
fi

public_keys=$(echo "$chosen_identities" | xargs -I {} bash -c "cat $rootdir/secrets/secrets.nix | grep {} | sed -nr 's/[[:space:]]+.*[[:space:]]+=[[:space:]](\".*\");/\\1/p'")

awk -v username=$username -v identities=$chosen_identities '!found && /# Machine keys/ { print "  \042" username "Password.age\042.publicKeys = [ " identities " ];"; found=1 } 1' $rootdir/secrets/secrets.nix | nixfmt > $rootdir/secrets/secrets_formatted.nix
mv $rootdir/secrets/secrets_formatted.nix $rootdir/secrets/secrets.nix

cd $rootdir/secrets

password=$(nix run $rootdir/utils/gum -- input --placeholder "password" --header "Password for user $username:" --header.foreground="99" --prompt.foreground="212" --password)
echo -e "$(tput setaf 99)Password for user $(tput setaf 212)$username$(tput setaf 99) entered$(tput sgr0)"

echo $password | openssl passwd -6 -stdin | nix run github:ryantm/agenix -- -e "${username}Password.age"

mkdir -p "$rootdir/users/$username"

cat <<EOF > "$rootdir/users/$username/default.nix"
{
  config,
  lib,
  pkgs,
  ...
}:
let
  USER = "${username}";
  listOfUsers = config.inventory.hosts."\${config.networking.hostName}".users.enableUsers;
in
{
  nebulis.users.users."\${USER}" = {
    isRoot = true;
    hasNixosPassword = true;
    authSshKeys = [
      $public_keys
    ];
    nixpkgs = {
      common = with pkgs; [ ];
      nixos = with pkgs; [ ];
    };
    homebrew = { };
  };
  home-manager.users."\${USER}" = lib.mkIf (lib.elem USER listOfUsers) {
    nebulis = {
      shared.basic.enable = true;
    };
    programs = { };
  };
}
EOF

nixfmt "$rootdir/users/$username/default.nix"

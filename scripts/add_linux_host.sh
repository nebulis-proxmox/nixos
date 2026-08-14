#!/bin/bash

set -e

tempdir=$(mktemp -d)

trap 'rm -rf "$tempdir"' EXIT

rootdir=$(git rev-parse --show-toplevel)

hostname=$(nix run $rootdir/utils/gum -- input --placeholder "new_host" --header "New Linux host name:" --header.foreground="99" --prompt.foreground="212")

previous_hosts=$(ls hosts/nixos)

if echo "$previous_hosts" | grep -q "^$hostname$"; then
    echo -e "$(tput setaf 208)Host $(tput setaf 212)$hostname$(tput setaf 208) already exists in hosts. Exiting.$(tput sgr0)"
    exit 1
fi

echo -e "$(tput setaf 99)Adding new host: $(tput setaf 212)$hostname$(tput sgr0)"

identities=$(cat $rootdir/secrets/secrets.nix | sed -nr 's/[[:space:]]+(.*)[[:space:]]+=[[:space:]]".*";/\1/p')

chosen_identities=$(nix run $rootdir/utils/gum -- choose --header "Select other identities then admins allowed to setup host $hostname:" $identities "Not listed here" --no-limit)

if echo "$chosen_identities" | grep -q "Not listed here"; then
    echo -e "$(tput setaf 208)Adding new identity for user $(tput setaf 212)$hostname$(tput setaf 208).$(tput sgr0)"

    $rootdir/scripts/add_identity.sh

    identities=$(cat $rootdir/secrets/secrets.nix | sed -nr 's/[[:space:]]+(.*)[[:space:]]+=[[:space:]]".*";/\1/p')

    chosen_identities=$(nix run $rootdir/utils/gum -- choose --header "Select identities allowed to setup host $hostname:" $identities --no-limit)
fi

users=$(nix run "$rootdir/utils/find" -- users -maxdepth 1 -mindepth 1 -type "d" | xargs -I {} basename {})

chosen_users=$(nix run $rootdir/utils/gum -- choose --header "Select users to install on $hostname:" $users "Not listed here" --no-limit)

if echo "$chosen_users" | grep -q "Not listed here"; then
    echo -e "$(tput setaf 208)Adding new user $(tput setaf 212)$hostname$(tput setaf 208).$(tput sgr0)"

    $rootdir/scripts/add_user.sh

    identities=$(cat $rootdir/secrets/secrets.nix | sed -nr 's/[[:space:]]+(.*)[[:space:]]+=[[:space:]]".*";/\1/p')

    chosen_users=$(nix run $rootdir/utils/gum -- choose --header "Select users to install on $hostname:" $users "Not listed here" --no-limit)
fi

public_keys=$(echo "$chosen_identities" | xargs -I {} bash -c "cat $rootdir/secrets/secrets.nix | grep {} | sed -nr 's/[[:space:]]+.*[[:space:]]+=[[:space:]](\".*\");/\\1/p'")

ssh-keygen -f "$tempdir/$hostname" -N "" -C ""

awk \
    -v hostname=$hostname \
    -v public_signature="$(cat ${tempdir}/${hostname}.pub | cut -d ' ' -f 1,2)" \
    '!found && /# Groups/ { print "  " hostname " = " "\042" public_signature "\042;\012"; found=1 } 1' \
    $rootdir/secrets/secrets.nix \
    | nix run github:NixOS/nixfmt > $rootdir/secrets/secrets_formatted.nix

mv $rootdir/secrets/secrets_formatted.nix $rootdir/secrets/secrets.nix

awk \
  -v hostname="${hostname}" \
  -v identities="${chosen_identities//$'\n'/ }" \
  '!found && /# Generic secrets/ { print "  \042" hostname ".age\042.publicKeys = [ " identities " " hostname " ] ++ admins;"; found=1 } 1' \
  $rootdir/secrets/secrets.nix \
  | nix run github:NixOS/nixfmt > $rootdir/secrets/secrets_formatted.nix

mv $rootdir/secrets/secrets_formatted.nix $rootdir/secrets/secrets.nix

cd $rootdir/secrets

cat "$tempdir/$hostname" | nix run github:ryantm/agenix -- -e "${hostname}.age"

mkdir -p "$rootdir/hosts/nixos/$hostname"

cat <<EOF > "$rootdir/hosts/nixos/$hostname/default.nix"
{ lib, ... }:

## Import all modules inside this folder recursively.
## from: https://github.com/evanjs/nixos_cfg/blob/4bb5b0b84a221b25cf50853c12b9f66f0cad3ea4/config/new-modules/default.nix
let
  # Recursively constructs an attrset of a given folder, recursing on directories, value of attrs is the filetype
  getDir =
    dir:
    lib.mapAttrs (
      file: type: if type == "directory" then getDir "\${dir}/\${file}" else type
      # If you want to exclude recusing on directories (untested)
      # if type == "directory" then null else type
    ) (builtins.readDir dir);
  # Collects all files of a directory as a list of strings of paths
  files =
    dir:
    lib.collect lib.isString (
      lib.mapAttrsRecursive (path: _type: lib.concatStringsSep "/" path) (getDir dir)
    );
  # Filters out directories that don't end with .nix or are this file, also makes the strings absolute
  validFiles =
    dir:
    map (file: ./. + "/\${file}") (
      lib.filter (
        file:
        lib.hasSuffix ".nix" file
        # Exclude this file
        && file != "default.nix"
        # how to exclude a path
        # && ! lib.hasPrefix "exclude/path/" file
        # how to exclude a group of files
        # && ! lib.hasSuffix "-ex.nix" file
      ) (files dir)
    );
in
{
  imports = validFiles ./.;
}
EOF

nix run github:NixOS/nixfmt "$rootdir/hosts/nixos/$hostname/default.nix"

cat <<EOF > "$rootdir/hosts/nixos/$hostname/$hostname.nix"
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
    networking.hostName = "$hostname";
    system.stateVersion = "26.05";

    nebulis = {
      autoUpgrade.enable = true;
    };
  };
}

EOF

nix run github:NixOS/nixfmt "$rootdir/hosts/nixos/$hostname/$hostname.nix"

quoted_users=$(echo $chosen_users | xargs -I {} bash -c "echo '\"{}\"'")

awk \
  -v hostname="${hostname}" \
  -v users="${quoted_users//$'\n'/ }" \
  '!found && /# Other inventory configuration/ { print "  config.inventory.hosts." hostname ".users.enableUsers = [ " users " ];"; found=1 } 1' \
  $rootdir/inventory.nix \
  | nix run github:NixOS/nixfmt > $rootdir/inventory_formatted.nix

mv $rootdir/inventory_formatted.nix $rootdir/inventory.nix

#!/bin/bash

hostname=$1
ipaddress=$2

shift 2

rootdir=$(git rev-parse --show-toplevel)
hosts=$(ls $rootdir/hosts/**)

temp=$(mktemp -d)

oldpwd="$PWD"
cd "$rootdir/secrets"

echo $temp

cleanup() {
    rm -rf "$temp"
    cd $oldpwd
}

trap cleanup EXIT

if [ -z "${hostname}" ]; then
    hostname=$(nix run $rootdir/utils/gum -- choose --header "Installing host:" $hosts)
fi

echo -e "$(tput setaf 99)Installing host: $(tput setaf 212)$hostname$(tput sgr0)"

if [ -z "${ipaddress}" ]; then
    ipaddress=$(nix run $rootdir/utils/gum -- input --placeholder "127.0.0.1" --header "IP Address to install:" --header.foreground="99" --prompt.foreground="212")
fi

echo -e "$(tput setaf 99)IP Address to install: $(tput setaf 212)$ipaddress$(tput sgr0)"

install -d -m755 "$temp/etc/ssh/"

nix run github:ryantm/agenix -- -d "$hostname.age" > "$temp/etc/ssh/$hostname"

chmod 600 "$temp/etc/ssh/$hostname"

nix run github:nix-community/nixos-anywhere -- \
    --build-on remote \
    --extra-files "$temp" \
    --generate-hardware-config nixos-generate-config "$rootdir/hosts/nixos/$hostname/hardware-configuration.nix" \
    --flake .#$hostname root@$ipaddress $@

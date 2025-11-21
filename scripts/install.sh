#!/bin/bash

hostname=$1
ipaddress=$2

shift 2

rootdir=$(git rev-parse --show-toplevel)

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
    echo "Please enter a valid hostname." > /dev/stderr
    exit 1
fi

if [ -z "${ipaddress}" ]; then
    echo "Please enter a valid IP address." > /dev/stderr
    exit 1
fi

install -d -m755 "$temp/etc/ssh/"

nix run github:ryantm/agenix -- -d "$hostname.age" > "$temp/etc/ssh/$hostname"

chmod 600 "$temp/etc/ssh/$hostname"


nix run github:nix-community/nixos-anywhere -- \
    --build-on remote \
    --extra-files "$temp" \
    --generate-hardware-config nixos-generate-config "$rootdir/hosts/nixos/$hostname/hardware-configuration.nix" \
    --flake .#$hostname root@$ipaddress $@

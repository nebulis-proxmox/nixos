#!/bin/bash

set -e

hostname=$1
ipaddress=$2

shift 2

rootdir=$(git rev-parse --show-toplevel)
user=$(whoami)

nix run $rootdir/utils/nixos-rebuild -- \
    --target-host "${user}@${ipaddress}" \
    --build-host "${user}@${ipaddress}" \
    --elevate=sudo --ask-elevate-password \
    --refresh \
    --flake github:nebulis-proxmox/nixos \
    --flake ".#${hostname}" \
    --upgrade \
    switch $@

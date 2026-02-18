# NixOS configuration for nebulis instances

> [!NOTE]  
> First runs of commands on this page can be long due to nix building its internal store

## Prerequisites

* `nix`

```bash
# Will install nix
curl -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate
```

## Manipulating secrets

```bash
# Add a new SSH based identity
./scripts/add_identity.sh

# Add, edit, rekey for other identities or remove secrets
# ./scripts/edit_secrets.sh
```

## Manipulating hosts

```bash
# Install a specific host
./scripts/install_host.sh

# Add or remove hosts
# ./scripts/edit_hosts.sh
```

## Manipulating users

```bash
# Add a new user
./scripts/add_user.sh
```

## Upgrade on host

```bash
nixos-rebuild switch --refresh --flake github:nebulis-proxmox/nixos --upgrade
````

#!/bin/bash

rootdir=$(git rev-parse --show-toplevel)

IFS=$'\n'
ssh_keys=$(ls $HOME/.ssh/id_* | grep -v '\.pub$' | xargs -I {} bash -c 'echo {}" "$(ssh-keygen -y -f {} | cut -d " " -f 3)')

chosen_ssh_key=$(nix run $rootdir/utils/gum -- choose --header "SSH identity to add:" $ssh_keys)

echo -e "$(tput setaf 99)SSH identity to add: $(tput setaf 212)$chosen_ssh_key$(tput sgr0)"

chosen_ssh_key_path=$(echo $chosen_ssh_key | cut -d ' ' -f 1)

public_signature=$(ssh-keygen -y -f $chosen_ssh_key_path | cut -d ' ' -f 1,2)

cat $rootdir/secrets/secrets.nix | grep -q "$public_signature"

if [ $? -eq 0 ]; then
    old_identity_name=$(cat $rootdir/secrets/secrets.nix | grep "$public_signature" | awk -F ' = ' '{print $1}' | tr -d ' ')

    echo -e "$(tput setaf 208)SSH identity already exists in secrets.nix under $(tput setaf 212)$old_identity_name$(tput sgr0)"

    nix run $rootdir/utils/gum -- confirm "Would you like to rename it?"

    if [ $? -eq 0 ]; then
        new_identity_name=$(nix run $rootdir/utils/gum -- input --placeholder "$old_identity_name" --header "Enter new identity name:" --header.foreground="99" --prompt.foreground="212")

        sed -i'' "s/$old_identity_name/$new_identity_name/g" $rootdir/secrets/secrets.nix

        echo -e "$(tput setaf 99)Renamed identity to: $(tput setaf 212)$new_identity_name$(tput sgr0)"
    else
        echo -e "$(tput setaf 208)Keeping existing identity name: $(tput setaf 212)$old_identity_name$(tput sgr0)"
    fi
    exit 0
fi

identity_name=$(nix run $rootdir/utils/gum -- input --placeholder "my_identity" --header "Adding identity as:" --header.foreground="99" --prompt.foreground="212")

echo -e "$(tput setaf 99)Adding identity as: $(tput setaf 212)$identity_name$(tput sgr0)"

awk -v identity_name=$identity_name -v public_signature=$public_signature '!found && /# Groups/ { print "  " identity_name " = " "\042" public_signature "\042;\012"; found=1 } 1' $rootdir/secrets/secrets.nix | nixfmt > $rootdir/secrets/secrets_formatted.nix
mv $rootdir/secrets/secrets_formatted.nix $rootdir/secrets/secrets.nix

echo -e "$(tput setaf 99)Successfully added identity: $(tput setaf 212)$identity_name$(tput sgr0)"

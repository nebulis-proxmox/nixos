#!/bin/bash

set -e

rootdir=$(git rev-parse --show-toplevel)
tempdir=$(mktemp -d)

mkdir -p "$rootdir/certs"

trap 'rm -rf "$tempdir"' EXIT

ca_name=$(nix run $rootdir/utils/gum -- input --placeholder "ca" --header "New CA name:" --header.foreground="99" --prompt.foreground="212")

signing_ca_keys=$()

if ls $rootdir/secrets/ca-*.key.age 2>/dev/null; then
    signing_ca_names=$(
        ls $rootdir/secrets/ca-*.key.age \
            | perl -pe "s|.*ca-(.+?)(-[0-9]+)?.key.age|\1|" \
            | uniq \
            | sort \
            | nix run $rootdir/utils/gum -- choose --header "Select an existing CA key to sign the new CA (or none for a root CA):" --no-limit
    )
else
    echo -e "$(tput setaf 208)No existing CA keys found to sign new CA $ca_name. Supposing root CA.$(tput sgr0)"
fi

identities=$(cat $rootdir/secrets/secrets.nix | sed -nr 's/[[:space:]]+(.*)[[:space:]]+=[[:space:]]".*";/\1/p')

chosen_identities=$(nix run $rootdir/utils/gum -- choose --header "Select identities to sign requests for CA $ca_name:" $identities "Not listed here" --no-limit)

if echo "$chosen_identities" | grep -q "Not listed here"; then
    echo -e "$(tput setaf 208)Adding new identity able to sign requests for CA $(tput setaf 212)$ca_name$(tput setaf 208).$(tput sgr0)"

    $rootdir/scripts/add_identity.sh

    identities=$(cat $rootdir/secrets/secrets.nix | sed -nr 's/[[:space:]]+(.*)[[:space:]]+=[[:space:]]".*";/\1/p')

    chosen_identities=$(nix run $rootdir/utils/gum -- choose --header "Select identities to sign requests for CA $ca_name:" $identities --no-limit)
fi

cat <<EOF > "$tempdir/ca.conf"
[ req ]
default_bits            = 2048
default_md              = sha256
distinguished_name      = dn
prompt                  = no

[ dn ]
C                       = FR
ST                      = ARA
L                       = Lyon
O                       = Nebulis
OU                      = Nebulis
CN                      = $ca_name, CA

[ root ]
basicConstraints        = critical,CA:TRUE
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
keyUsage                = critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign

[ ca ]
basicConstraints        = critical,CA:TRUE
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer:always
keyUsage                = critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign
EOF

nix run $rootdir/utils/openssl -- genpkey -algorithm ED25519 -out "$tempdir/ca-$ca_name.key"

cd $rootdir/secrets

if [ -z "$signing_ca_names" ]; then
    nix run $rootdir/utils/openssl -- \
        req -x509 -new -sha512 -noenc \
            -key "$tempdir/ca-$ca_name.key" -days 3650 \
            -config "$tempdir/ca.conf" \
            -extensions root \
            -out "$tempdir/ca-$ca_name.crt"
else
    nix run $rootdir/utils/openssl -- \
        req -new -sha512 \
            -key "$tempdir/ca-$ca_name.key" \
            -config "$tempdir/ca.conf" \
            -out "$tempdir/ca-$ca_name.csr"

    ca_index=0

    if [ $(echo $signing_ca_names | wc -w) -gt 1 ]; then
        # Multiple signing CAs
        for signing_ca_name in $signing_ca_names; do
            if [ $(ls $rootdir/certs/ca-$signing_ca_name-*.crt 2>/dev/null | wc -l) -eq 0 ]; then
                ca_index=`expr $ca_index + 1`

                echo -e "$(tput setaf 208)Signing CA $(tput setaf 212)$signing_ca_name$(tput setaf 208) has only one version.$(tput sgr0)"
                
                # Single version of signing CA found
                nix run $rootdir/utils/openssl -- \
                    x509 -req \
                        -in "$tempdir/ca-$ca_name.csr" \
                        -CA "$rootdir/certs/ca-$signing_ca_name.crt" \
                        -CAkey <(nix run github:ryantm/agenix -- -d "ca-$signing_ca_name.key.age") \
                        -out "$tempdir/ca-$ca_name-$ca_index.crt" \
                        -days 1825 \
                        -sha512 \
                        -extfile "$tempdir/ca.conf" \
                        -extensions ca
                
                echo -e "$(tput setaf 99)Signed certificate $(tput setaf 212)ca-$ca_name-$ca_index.crt.$(tput sgr0)"
            else
                # Multiple versions of signing CA found
                for signing_ca_cert in $(ls $rootdir/certs/ca-$signing_ca_name-*.crt 2>/dev/null); do
                    ca_index=`expr $ca_index + 1`
                    
                    nix run $rootdir/utils/openssl -- \
                        x509 -req \
                            -in "$tempdir/ca-$ca_name.csr" \
                            -CA "$signing_ca_cert" \
                            -CAkey <(nix run github:ryantm/agenix -- -d "ca-$signing_ca_name.key.age") \
                            -out "$tempdir/ca-$ca_name-$ca_index.crt" \
                            -days 1825 \
                            -sha512 \
                            -extfile "$tempdir/ca.conf" \
                            -extensions ca
                done
            fi
        done
    else
        # Single signing CA
        if [ $(ls $rootdir/certs/ca-$signing_ca_names-*.crt 2>/dev/null | wc -l) -eq 0 ]; then
            # Single version of signing CA found
            nix run $rootdir/utils/openssl -- \
                x509 -req \
                    -in "$tempdir/ca-$ca_name.csr" \
                    -CA "$rootdir/certs/ca-$signing_ca_names.crt" \
                    -CAkey <(nix run github:ryantm/agenix -- -d "ca-$signing_ca_names.key.age") \
                    -out "$tempdir/ca-$ca_name.crt" \
                    -days 1825 \
                    -sha512 \
                    -extfile "$tempdir/ca.conf" \
                    -extensions ca
        else
            # Multiple versions of signing CA found
            for signing_ca_cert in $(ls $rootdir/certs/ca-$signing_ca_names-*.crt 2>/dev/null); do
                ca_index=`expr $ca_index + 1`
                
                nix run $rootdir/utils/openssl -- \
                    x509 -req \
                        -in "$tempdir/ca-$ca_name.csr" \
                        -CA "$signing_ca_cert" \
                        -CAkey <(nix run github:ryantm/agenix -- -d "ca-$signing_ca_names.key.age") \
                        -out "$tempdir/ca-$ca_name-$ca_index.crt" \
                        -days 1825 \
                        -sha512 \
                        -extfile "$tempdir/ca.conf" \
                        -extensions ca
            done
        fi
    fi
fi

awk \
    -v ca_name="${ca_name}" \
    -v identities="${chosen_identities//$'\n'/ }" \
    '!found && /# END_SECRETS/ { print "  \042ca-" ca_name ".key.age\042.publicKeys = [ " identities " ];"; found=1 } 1' \
    $rootdir/secrets/secrets.nix \
    | nixfmt > $rootdir/secrets/secrets_formatted.nix

mv $rootdir/secrets/secrets_formatted.nix $rootdir/secrets/secrets.nix

cat "$tempdir/ca-$ca_name.key" | nix run github:ryantm/agenix -- -e "ca-${ca_name}.key.age"

cp $tempdir/ca-$ca_name*.crt "$rootdir/certs"

mkCert () {
    local ca="$1"
    local cert="$2"
    local expirationDays="$3"
    local subject="$4"
    local altNamesExt="$5"

    if [ ! -f "$ca.crt" ] || [ ! -f "$ca.key" ]; then
        echo "Required $ca CA is missing, cannot create $cert certificate."
        exit 1
    fi

    if [ ! -f "$cert.key" ]; then
        openssl genpkey -algorithm ED25519 -out "$cert.key"
        chmod 600 "$cert.key"
    fi

    if [ ! -f "$cert.crt" ] || ! openssl x509 -checkend 86400 -noout -in "$cert.crt"; then
        if [ -z "$altNamesExt" ]; then
            openssl req -new \
                -key "$cert.key" \
                -subj "$subject" \
                -out "$cert.csr"

            openssl x509 -req \
                -in "$cert.csr" \
                -CA "$ca.crt" \
                -CAkey "$ca.key" \
                -out "$cert.crt" \
                -days "$expirationDays" \
                -sha512
        else
            openssl req -new \
                -key "$cert.key" \
                -subj "$subject" \
                -addext "$altNamesExt" \
                -out "$cert.csr"

            openssl x509 -req \
                -in "$cert.csr" \
                -CA "$ca.crt" \
                -CAkey "$ca.key" \
                -out "$cert.crt" \
                -days "$expirationDays" \
                -extfile <(echo "$altNamesExt") \
                -sha512
        fi

        chmod 644 "$cert.crt"
        rm -f "$cert.csr"
    fi
}

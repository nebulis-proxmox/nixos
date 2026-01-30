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

    if [ ! -z "$subject" ]; then
        local subjectArg="-subj '$subject'"
    fi

    if [ ! -z "$altNamesExt" ]; then
        local altNamesExtArg="-addext \"$altNamesExt\""
        local altNamesExtFileArg="-extfile <(echo \"$altNamesExt\")"
    fi

    if [ ! -f "$cert.crt" ] || ! openssl x509 -checkend 86400 -noout -in "$cert.crt"; then
        openssl req -new \
            -key "$cert.key" \
            $subjectArg \
            $altNamesExtArg \
            -out "$cert.csr"

        openssl x509 -req \
            -in "$cert.csr" \
            -CA "$ca.crt" \
            -CAkey "$ca.key" \
            -out "$cert.crt" \
            -days $expirationDays \
            $altNamesExtFileArg \
            -sha512
        
        chmod 644 "$cert.crt"
        rm -f "$cert.csr"
    fi
}

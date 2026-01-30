mkKubeconfig () {
    local ca="$1"
    local kubeconfig="$2"
    local clusterAddr="$3"
    local expirationDays="$4"
    local username="$5"
    local group="$6"

    if [ ! -f "${ca}.crt" ] || [ ! -f "${ca}.key" ]; then
        echo "Required $ca CA is missing, cannot create $kubeconfig kubeconfig."
        exit 1
    fi

    # TODO: handle expiration of kubeconfig
    if [ ! -f "$kubeconfig" ]; then
        if [ -z "$group" ]; then
            $NIX_MK_CERT
        else
            $NIX_MK_CERT_WITH_GROUP
        fi

        jq -ncr \
        --arg caData "$(base64 -w0 \"${ca}.crt\")" \
        --arg clientCertData "$(base64 -w0 \"${kubeconfig}.crt\")" \
        --arg clientKeyData "$(base64 -w0 \"${kubeconfig}.key\")" \
        --arg clusterAddr "$clusterAddr" \
        --arg username "$username" \
        '{
            apiVersion: "v1",
            kind: "Config",
            clusters: [
            {
                name: "kubernetes",
                cluster: {
                "certificate-authority-data": $caData,
                server: "https://" + $clusterAddr
                }
            }
            ],
            contexts: [
            {
                name: $username + "@kubernetes",
                context: {
                cluster: "kubernetes",
                user: $username
                }
            }
            ],
            "current-context": $username + "@kubernetes",
            users: [
            {
                name: $username,
                user: {
                "client-certificate-data": $clientCertData,
                "client-key-data": $clientKeyData
                }
            }
            ]
        }' > "$kubeconfig"

        rm -f "${kubeconfig}.key" "${kubeconfig}.csr" "${kubeconfig}.crt"

        chmod 600 "$kubeconfig"
    fi
}
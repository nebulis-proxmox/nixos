function addLabelOnNode() {
    local nodeName="$1"
    local label="$2"

    $KUBECTL get node "$nodeName" -o json | jq --arg label "$label" '.metadata.labels += { $label: "" }' | $KUBECTL apply -f -
}

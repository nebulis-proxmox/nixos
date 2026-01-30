function removeLabelOnNode() {
    local nodeName="$1"
    local label="$2"

    $KUBECTL get node "$nodeName" -o json | jq --arg label "$label" '.metadata.labels |= with_entries(select(.key == $label | not))' | $KUBECTL apply -f -
}

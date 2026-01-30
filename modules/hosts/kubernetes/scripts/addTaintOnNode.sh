function addTaintOnNode() {
    local nodeName="$1"
    local taintType="$2"
    local taintEffect="NoSchedule"

    $KUBECTL get node "$nodeName" -o json | jq --arg taintType "$taintType" --arg taintEffect "$taintEffect" '.spec.taints += [{key: $taintType, effect: $taintEffect}] | .spec.taints |= unique_by(.key)' | $KUBECTL apply -f -
}

function removeTaintOnNode() {
    local nodeName="$1"
    local taintType="$2"

    $KUBECTL get node "$nodeName" -o json | jq --arg taintType "$taintType" '.spec.taints |= map(select(.key != $taintType))' | $KUBECTL apply -f -
}

#!/usr/bin/env bash
set -euo pipefail

: "${KUBE_CONTEXT:?Đặt KUBE_CONTEXT tới cluster cần kiểm tra}"
command -v kubectl >/dev/null || { echo 'Thiếu kubectl' >&2; exit 1; }
command -v jq >/dev/null || { echo 'Thiếu jq' >&2; exit 1; }
command -v helm >/dev/null || { echo 'Thiếu Helm' >&2; exit 1; }

kubectl_cmd=(kubectl --context "$KUBE_CONTEXT" --request-timeout=20s)
echo "Kiểm tra context: $KUBE_CONTEXT"
"${kubectl_cmd[@]}" cluster-info >/dev/null

nodes_json="$("${kubectl_cmd[@]}" get nodes -o json)"
ready_nodes="$(jq '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes_json")"
ready_zones="$(jq '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | .metadata.labels["topology.kubernetes.io/zone"] // empty] | unique | length' <<<"$nodes_json")"
echo "Node Ready có thể lập lịch: $ready_nodes; AZ: $ready_zones"
if (( ready_nodes < 3 || ready_zones < 3 )); then
  echo 'Cần ít nhất 3 node Ready trên 3 AZ cho Redis và Sentinel.' >&2
  exit 1
fi

"${kubectl_cmd[@]}" get csidriver ebs.csi.aws.com >/dev/null || {
  echo 'Chưa có Amazon EBS CSI driver (ebs.csi.aws.com).' >&2
  exit 1
}

echo 'Preflight đạt. Kiểm tra thêm dung lượng node, quyền kéo image và backup trước khi cài.'

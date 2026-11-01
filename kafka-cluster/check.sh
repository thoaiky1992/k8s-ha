#!/usr/bin/env bash

export KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
bash <<'BASH'
set -euo pipefail

: "${KUBE_CONTEXT:?Đặt KUBE_CONTEXT tới cluster cần kiểm tra}"
command -v kubectl >/dev/null || { echo 'Thiếu kubectl' >&2; exit 1; }
command -v jq >/dev/null || { echo 'Thiếu jq' >&2; exit 1; }

kubectl_cmd=(kubectl --context "$KUBE_CONTEXT" --request-timeout=20s)
failed=0

echo "Kiểm tra context: $KUBE_CONTEXT"

# Kiểm tra một node group theo label workload: cần tối thiểu $2 node Ready, trải đều trên đúng $3 AZ,
# mỗi AZ tối thiểu $4 node. Node thiếu nhãn zone bị coi là lỗi vì rack awareness và topologySpreadConstraints cần nhãn này.
check_node_group() {
  local workload="$1" min_nodes="$2" min_zones="$3" min_per_zone="$4"
  local nodes_json ready_nodes zone_counts zones min_per_zone_found

  nodes_json="$("${kubectl_cmd[@]}" get nodes -l "workload=$workload" -o json)"
  ready_nodes="$(jq '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes_json")"
  zone_counts="$(jq -r '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | .metadata.labels["topology.kubernetes.io/zone"] // empty] | group_by(.) | map(length) | "\(length) \(min // 0)"' <<<"$nodes_json")"
  read -r zones min_per_zone_found <<<"$zone_counts"
  echo "Node $workload Ready: $ready_nodes; AZ: $zones; số node nhỏ nhất mỗi AZ: $min_per_zone_found"

  if (( ready_nodes < min_nodes || zones < min_zones || min_per_zone_found < min_per_zone )); then
    echo "FAIL: Cần ít nhất $min_nodes node Ready trong node group $workload (workload=$workload), phân bổ trên $min_zones AZ (tối thiểu $min_per_zone node mỗi AZ)." >&2
    failed=1
  fi

  if (( $(jq '[.items[] | select(.metadata.labels["topology.kubernetes.io/zone"] == null)] | length' <<<"$nodes_json") > 0 )); then
    echo "FAIL: Có node $workload thiếu nhãn topology.kubernetes.io/zone." >&2
    failed=1
  fi
}

# Broker Kafka: sáu node, hai mỗi AZ (kafka-nodepool.yaml).
check_node_group kafka 6 3 2
# Kafka Connect: ba node, một mỗi AZ (kafka-connect.yaml, Terraform 01.nodes.tf).
check_node_group kafka-connect 3 3 1

if "${kubectl_cmd[@]}" get csidriver ebs.csi.aws.com >/dev/null 2>&1; then
  echo 'EBS CSI driver: có'
else
  echo 'FAIL: Chưa có Amazon EBS CSI driver (ebs.csi.aws.com).' >&2
  failed=1
fi

if "${kubectl_cmd[@]}" get storageclass kafka-gp3 >/dev/null 2>&1; then
  echo 'StorageClass kafka-gp3: có'
else
  echo 'Chưa có StorageClass kafka-gp3: áp dụng kafka-cluster/storage-class.yaml trước khi tạo Kafka.' >&2
  failed=1
fi

if (( failed )); then
  echo 'Preflight chưa đạt; không cài Strimzi/Kafka.' >&2
  exit 1
fi
echo 'Preflight đạt. Tiếp tục theo README.md.'
BASH

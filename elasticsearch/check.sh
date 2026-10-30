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
version_json="$("${kubectl_cmd[@]}" get --raw /version)"
k8s_version="$(jq -r '.gitVersion' <<<"$version_json")"
k8s_minor="$(jq -r '.minor | capture("(?<minor>[0-9]+)").minor | tonumber' <<<"$version_json")"
echo "Kubernetes: $k8s_version"
if (( k8s_minor < 31 || k8s_minor > 36 )); then
  echo 'FAIL: ECK 3.5 hỗ trợ Kubernetes 1.31–1.36 theo tài liệu Elastic hiện tại.' >&2
  failed=1
fi

# Đếm node của node group elasticsearch (label workload=elasticsearch, Terraform 01.nodes.tf).
nodes_json="$("${kubectl_cmd[@]}" get nodes -l workload=elasticsearch -o json)"
es_ready_nodes="$(jq '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes_json")"
es_zone_counts="$(jq -r '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | .metadata.labels["topology.kubernetes.io/zone"] // empty] | group_by(.) | map(length) | "\(length) \(min // 0)"' <<<"$nodes_json")"
read -r es_zones es_min_per_zone <<<"$es_zone_counts"
echo "Node elasticsearch Ready: $es_ready_nodes; AZ: $es_zones; số node nhỏ nhất mỗi AZ: $es_min_per_zone"
if (( es_ready_nodes < 6 || es_zones < 3 || es_min_per_zone < 2 )); then
  echo 'FAIL: Cần ít nhất sáu node Ready trong node group elasticsearch (workload=elasticsearch), phân bổ đều ba AZ (tối thiểu hai node mỗi AZ).' >&2
  failed=1
fi

if "${kubectl_cmd[@]}" get csidriver ebs.csi.aws.com >/dev/null 2>&1; then
  echo 'EBS CSI driver: có'
else
  echo 'FAIL: Chưa có Amazon EBS CSI driver (ebs.csi.aws.com).' >&2
  failed=1
fi

if (( failed )); then
  echo 'Preflight chưa đạt; không cài ECK/Elasticsearch.' >&2
  exit 1
fi
echo 'Preflight đạt. Tiếp tục kiểm tra sizing, snapshot và quyền privileged trước khi cài.'
BASH

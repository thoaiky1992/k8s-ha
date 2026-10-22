#!/usr/bin/env bash

export KUBE_CONTEXT="$(kubectl config current-context)"
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

nodes_json="$("${kubectl_cmd[@]}" get nodes -o json)"
ready_nodes="$(jq '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$nodes_json")"
ready_zones="$(jq '[.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | .metadata.labels["topology.kubernetes.io/zone"] // empty] | unique | length' <<<"$nodes_json")"
echo "Node Ready có thể lập lịch: $ready_nodes; AZ: $ready_zones"
if (( ready_nodes < 3 || ready_zones < 3 )); then
  echo 'FAIL: Cần ít nhất ba node Ready, mỗi node ở một AZ khác nhau.' >&2
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

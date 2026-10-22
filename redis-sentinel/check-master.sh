#!/usr/bin/env bash
# Kiểm tra Sentinel đã đăng ký master và master đang là primary đúng số replica.
# redis-cli chạy bên trong Pod Sentinel và dùng REDISCLI_AUTH có sẵn trong Pod,
# nên mật khẩu không được đưa ra máy này và không được in ra.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
NAMESPACE="${NAMESPACE:-redis-sentinel}"
SENTINEL_POD="${SENTINEL_POD:-redis-sentinel-sentinel-0}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-2}"
SENTINEL_HOST="redis-sentinel-sentinel.${NAMESPACE}.svc.cluster.local"
SENTINEL_PORT=26379

command -v kubectl >/dev/null || { echo 'Thiếu kubectl' >&2; exit 1; }

kubectl_cmd=(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE")

# Chạy redis-cli trong Pod Sentinel tới host:port, TLS xác minh bằng CA đã mount ở /tls.
pod_cli() {
  local host="$1" port="$2"
  shift 2
  "${kubectl_cmd[@]}" exec "$SENTINEL_POD" -- redis-cli --tls --cacert /tls/ca.crt \
    --sni "$host" -h "$host" -p "$port" "$@"
}

failed=0
echo "Context: $KUBE_CONTEXT | namespace: $NAMESPACE | pod: $SENTINEL_POD"

# 1. Sentinel có trả về địa chỉ master không.
mapfile -t master < <(pod_cli "$SENTINEL_HOST" "$SENTINEL_PORT" --raw \
  SENTINEL get-master-addr-by-name "$MASTER_NAME")
master_host="${master[0]:-}"
master_port="${master[1]:-}"
if [[ -z "$master_host" || ! "$master_port" =~ ^[0-9]+$ ]]; then
  echo "FAIL: Sentinel chưa đăng ký master '$MASTER_NAME'." >&2
  exit 1
fi
echo "OK: Sentinel báo master '$MASTER_NAME' = $master_host:$master_port"

# 2. Đủ quorum và failover khả dụng.
if quorum_out="$(pod_cli "$SENTINEL_HOST" "$SENTINEL_PORT" SENTINEL ckquorum "$MASTER_NAME" 2>&1)"; then
  echo "Quorum: $quorum_out"
else
  echo "FAIL: ckquorum: $quorum_out" >&2
  failed=1
fi

# 3. Chính master phải báo role:master và đủ replica kết nối.
info="$(pod_cli "$master_host" "$master_port" --raw INFO replication | tr -d '\r')"
role="$(awk -F: '/^role:/{print $2}' <<<"$info")"
replicas="$(awk -F: '/^connected_slaves:/{print $2}' <<<"$info")"
if [[ "$role" != "master" ]]; then
  echo "FAIL: $master_host báo role='$role', không phải master." >&2
  failed=1
else
  echo "OK: $master_host role=master"
fi
if (( ${replicas:-0} < EXPECTED_REPLICAS )); then
  echo "FAIL: connected_slaves=${replicas:-0}, cần ít nhất $EXPECTED_REPLICAS." >&2
  failed=1
else
  echo "OK: connected_slaves=$replicas"
fi

if (( failed )); then
  exit 1
fi
echo 'Sentinel đã đăng ký master và master hoạt động đúng.'

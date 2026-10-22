# Elasticsearch HA trên EKS với Elastic Cloud on Kubernetes (ECK)

Bộ file này cài **ECK operator bằng Helm** và tạo Elasticsearch 3 node, mỗi node trên một host và một AZ khác nhau. Mỗi node dùng PVC EBS gp3 riêng. Endpoint nội bộ là `https://search-es-http.elasticsearch.svc:9200`. ECK tự tạo chứng chỉ TLS và Service. Đây là cấu hình nền; cần tính dung lượng theo dữ liệu thực tế và cấu hình snapshot trước khi phục vụ dữ liệu production.

## Các file

| File | Vai trò |
| --- | --- |
| `namespace.yaml` | Tạo `elasticsearch` cho cluster và `elastic-system` cho ECK operator. |
| `pv.yaml` | StorageClass `elasticsearch-gp3` cho EBS CSI; PV thật được cấp động. |
| `pvc.yaml` | PVC và Pod **thử storage**, chỉ áp dụng thủ công khi cần kiểm tra. |
| `secret.yaml` | Mẫu Secret chứa mật khẩu tài khoản `elastic`. |
| `manifest.yaml` | Elasticsearch CR; ECK tạo 3 PVC từ `volumeClaimTemplates`. |
| `eck-values.yaml` | 2 replica operator, tách node bằng pod anti-affinity. |

Không tạo PV tĩnh hoặc áp dụng `pvc.yaml` trong lệnh cài thông thường: ECK phải quản lý PVC dữ liệu của các node. `reclaimPolicy: Retain` và `volumeClaimDeletePolicy: DeleteOnScaledownOnly` giúp giữ dữ liệu khi xóa Elasticsearch CR; khi giảm `count`, PVC của node bị giảm vẫn có thể bị xóa. Cần kiểm tra PV/EBS volume trước khi dọn tài nguyên.

## Cài Helm trên Debian/Ubuntu bằng Apt

Chạy trên **máy thực thi các lệnh cài đặt**, không cần chạy trên mọi node EKS. Dùng kho Apt hiện tại theo [hướng dẫn Helm](https://v3.helm.sh/docs/v3/intro/install/#from-apt-debianubuntu). Không dùng `baltocdn.com`: [Helm đã ngừng dùng domain đó và cảnh báo rủi ro bảo mật](https://blog.helm.sh/blog/security-notice-baltocdn/).

```bash
(
  set -euo pipefail
  helm_key_file="$(mktemp)"
  trap 'rm -f "$helm_key_file"' EXIT

  sudo apt-get update
  sudo apt-get install -y curl gpg apt-transport-https
  curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey -o "$helm_key_file"

  expected_fingerprint=DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6
  actual_fingerprint="$(gpg --show-keys --with-colons "$helm_key_file" | awk -F: '$1 == "fpr" {print $10; exit}')"
  if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
    echo "Khóa Apt của Helm không đúng fingerprint: $actual_fingerprint" >&2
    exit 1
  fi

  gpg --dearmor < "$helm_key_file" | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
  echo 'deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main' \
    | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y helm
)
helm version --short
```

## Điều kiện trước khi cài

- `kubectl`, `jq`, Helm 3 và quyền quản trị để cài CRD toàn cluster. Máy chạy các lệnh phải truy cập được `https://helm.elastic.co`; cluster phải kéo được ảnh từ `docker.elastic.co`.
- ECK 3.5 hiện hỗ trợ Kubernetes **1.31–1.36**. Kiểm tra lại [ma trận hỗ trợ ECK](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s) trước khi nâng phiên bản. Cluster `dev-demo` kiểm tra ngày 24/10/2026 đang chạy **1.37** (API server 1.37.0, node đã thấy 1.37.1), vượt dải hỗ trợ công bố; không triển khai cấu hình này lên cluster đó cho production cho đến khi có phiên bản ECK hỗ trợ 1.37 hoặc một cluster dùng Kubernetes được hỗ trợ.
- EKS dùng **managed EC2 node group thông thường**, không phải EKS Auto Mode. Cần Amazon EBS CSI Driver (`ebs.csi.aws.com`) với IAM permission tạo EBS volume. [Hướng dẫn EBS CSI của AWS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html). Nếu dùng EKS Auto Mode, phải đổi provisioner và cách cài theo [StorageClass cho Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/create-storage-class.html).
- Ít nhất **3 node Ready trên 3 AZ**, mỗi node còn ít nhất 1 vCPU và 4 GiB RAM cho Elasticsearch, cộng tài nguyên hệ thống và operator. [`terraform/08-nodes.tf`](../terraform/08-nodes.tf) hiện chỉ dùng **hai AZ**; tăng `desired_size` trong node group hiện tại không đáp ứng điều kiện này. Cần mở rộng hạ tầng sang AZ thứ ba và xác nhận có node Ready ở đó trước khi cài. EBS gắn với AZ của PVC; sau sự cố mất AZ, pod dùng PVC cũ không thể tự chuyển sang AZ khác.
- `KUBE_CONTEXT` phải trỏ đúng cluster. Kiểm tra bằng `kubectl config get-contexts` và `kubectl --context "$KUBE_CONTEXT" get nodes -o wide`.
- Init container `sysctl` trong `manifest.yaml` cần quyền `privileged` để đặt `vm.max_map_count=1048576`. Nếu chính sách cluster không cho phép, cấu hình sysctl trên node hoặc qua DaemonSet được quản trị riêng trước khi cài, rồi bỏ init container. [Hướng dẫn Elastic về mmap](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/virtual-memory).

Cluster trong repo mới có hai AZ. Đây là thay đổi hạ tầng cần thiết, không thể giải quyết bằng cách tăng số replica Elasticsearch. Nếu mở rộng Terraform, hãy tạo subnet/node capacity trong AZ thứ ba rồi chạy phần kiểm tra bên dưới. Kiểm tra `terraform plan` trước mọi `apply` vì thay đổi subnet của node group hiện có có thể đòi hỏi thay thế node group.

EBS CSI add-on và IAM role dùng Pod Identity được khai báo tại [`terraform/16-ebs-csi-addon.tf`](../terraform/16-ebs-csi-addon.tf). Áp dụng Terraform trước khi tạo PVC Elasticsearch; nếu dùng hạ tầng khác, cài driver và IAM permission theo [hướng dẫn AWS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html). Nếu pod `Pending` và PVC báo `ExternalProvisioning`, kiểm tra `kubectl get csidriver ebs.csi.aws.com` và pod `ebs-csi-controller` trong `kube-system`.

## Kiểm tra trước khi cài

Chạy khối lệnh này từ thư mục gốc repo. Nó chỉ đọc Kubernetes API và dừng với mã lỗi nếu cluster chưa đáp ứng phiên bản ECK 3.5, ba AZ hoặc EBS CSI. Cập nhật dải phiên bản khi đổi phiên bản operator theo [ma trận hỗ trợ ECK](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s).

```bash
export KUBE_CONTEXT="<ten-kubectl-context>"
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
```

## Cài operator và Elasticsearch

Chỉ tiếp tục khi khối kiểm tra trên thành công. Chạy các lệnh sau từ thư mục gốc repo. Đặt context chính xác để tránh cài nhầm cluster. Mật khẩu trong `secret.yaml` chỉ là mẫu; thay bằng mật khẩu mạnh trong file local và không commit file đó. File `secret.local.yaml` được bỏ qua bởi `.gitignore`. ECK chấp nhận Secret kiểu `kubernetes.io/basic-auth` làm file realm; tài khoản `elastic` sẽ dùng mật khẩu này.

```bash
set -euo pipefail
cp elasticsearch/secret.yaml elasticsearch/secret.local.yaml
chmod 600 elasticsearch/secret.local.yaml
${EDITOR:-vi} elasticsearch/secret.local.yaml
export KUBE_CONTEXT="<ten-kubectl-context>"

# Tạo namespace và StorageClass gp3.
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/pv.yaml

# Cài ECK operator bằng Helm.
helm repo add elastic https://helm.elastic.co --force-update
helm repo update elastic
helm --kube-context "$KUBE_CONTEXT" upgrade --install elastic-operator elastic/eck-operator \
  --namespace elastic-system --version 3.5.0 \
  -f elasticsearch/eck-values.yaml --wait --timeout 10m
kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/elasticsearches.elasticsearch.k8s.elastic.co --timeout=120s

# Tạo Secret xác thực và Elasticsearch cluster.
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/secret.local.yaml
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/rolemapping.yaml
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/manifest.yaml

# Đợi cluster khỏe và kiểm tra tài nguyên.
kubectl --context "$KUBE_CONTEXT" wait -n elasticsearch \
  --for=jsonpath='{.status.health}'=green \
  elasticsearch.elasticsearch.k8s.elastic.co/search --timeout=15m
kubectl --context "$KUBE_CONTEXT" get -n elasticsearch elasticsearch/search
kubectl --context "$KUBE_CONTEXT" get -n elasticsearch pods \
  -l elasticsearch.k8s.elastic.co/cluster-name=search -o wide
kubectl --context "$KUBE_CONTEXT" get -n elasticsearch pvc
kubectl --context "$KUBE_CONTEXT" get -n elasticsearch service search-es-http
```

Không áp dụng `secret.yaml` chứa mật khẩu mẫu. Có thể chạy lại lệnh Helm `upgrade --install` sau khi sửa `eck-values.yaml`; sau khi sửa `manifest.yaml`, áp dụng lại manifest bằng `kubectl apply`. Không cài chồng operator khác đang quản lý cùng CRD/namespace nếu chưa kiểm tra quyền sở hữu Helm release.

## Kiểm tra cluster và truy cập

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get elasticsearch search
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pods -l elasticsearch.k8s.elastic.co/cluster-name=search -o wide
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pvc -o wide
kubectl --context "$KUBE_CONTEXT" get pv
kubectl --context "$KUBE_CONTEXT" -n elastic-system get pods -o wide
```

Kỳ vọng 3 Elasticsearch pod trên 3 node **và 3 AZ khác nhau**, 3 PVC `Bound`, Elasticsearch `health=green`. Xác nhận các index production có ít nhất một replica (`number_of_replicas >= 1`); cấu hình ba node không tự bảo vệ index có replica bằng 0. Kiểm tra HTTPS qua port-forward trong terminal riêng:

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch port-forward service/search-es-http 9200:9200
```

Terminal thứ hai:

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get secret search-es-http-certs-public \
  -o go-template='{{index .data "ca.crt" | base64decode}}' > /tmp/search-ca.crt
read -r -s -p 'Mật khẩu elastic: ' ELASTIC_PASSWORD; printf '\n'
curl --cacert /tmp/search-ca.crt -u "elastic:$ELASTIC_PASSWORD" \
  https://localhost:9200/_cluster/health?pretty
unset ELASTIC_PASSWORD
```

Không dùng `curl -k` cho kết nối thật. Sau khi kiểm tra, xóa `/tmp/search-ca.crt` nếu không còn cần.

## Kiểm tra riêng StorageClass (tùy chọn)

`pvc.yaml` tạo PVC 1 GiB và Pod ghi file để kích hoạt `WaitForFirstConsumer`. Bài kiểm tra này tạo một EBS volume có chi phí:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/pvc.yaml
kubectl --context "$KUBE_CONTEXT" -n elasticsearch wait --for=condition=Ready pod/elasticsearch-storage-check --timeout=5m
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pvc elasticsearch-storage-check -o wide
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pvc elasticsearch-storage-check -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl --context "$KUBE_CONTEXT" delete -f elasticsearch/pvc.yaml
```

Do StorageClass dùng `Retain`, PV và EBS volume của bài kiểm tra không tự xóa. Ghi lại tên PV/volume ID và chỉ xóa chúng sau khi chắc chắn đó là dữ liệu thử. Nếu Pod/PVC `Pending`, kiểm tra `kubectl --context "$KUBE_CONTEXT" -n elasticsearch describe pvc elasticsearch-storage-check`, sự kiện Pod và quyền IAM của EBS CSI.

## Lưu ý vận hành

- Elasticsearch 3 node chịu được lỗi một node khi shard replica được cấu hình và cluster có tài nguyên đủ. Pod anti-affinity yêu cầu 3 node; khi chỉ còn 2 node, pod thứ ba có thể Pending đến khi node thay thế sẵn sàng.
- EBS volume gắn theo AZ. Pod với PVC đã bound không tự chuyển AZ. Thiết lập snapshot repository trên S3, Snapshot Lifecycle Management (SLM), cảnh báo snapshot lỗi và **thử restore** trước khi đưa dữ liệu production vào. [Hướng dẫn snapshot trên ECK](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/cloud-on-k8s). HA không thay thế backup.
- `20Gi` mỗi PVC và `4Gi` RAM/1 vCPU mỗi pod chỉ là cấu hình khởi điểm. Tính dung lượng từ tốc độ ghi, thời gian giữ dữ liệu, số replica, watermark, shard và thời gian phục hồi; tăng PVC trước khi gần đầy. Theo dõi heap, disk, CPU, cluster health và số shard.
- Muốn tăng dung lượng PVC, tăng `storage` trong `manifest.yaml`; không giảm kích thước hoặc đổi StorageClass của PVC đã tạo. [ECK volume claim templates](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/volume-claim-templates).
- Trước khi nâng ECK hoặc Elasticsearch, kiểm tra [tài liệu cài ECK bằng Helm](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/install) và quy trình nâng cấp tương ứng. CRD là tài nguyên toàn cluster; không xóa CRD khi chỉ gỡ một Elasticsearch cluster.

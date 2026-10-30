# Elasticsearch HA trên EKS với Elastic Cloud on Kubernetes (ECK)

Bộ file này cài **ECK operator bằng Helm** và tạo Elasticsearch 6 node, mỗi AZ 2 node trên 3 AZ, mỗi node trên một host khác nhau. Mỗi node dùng PVC EBS gp3 riêng. Với 6 node master-eligible, quorum là 4: cụm chịu được mất một node hoặc một AZ. Endpoint nội bộ là `https://search-es-http.elasticsearch.svc:9200`. Manifest bật rõ ràng HTTPS với chứng chỉ tự ký do ECK tự cấp và xoay vòng; TLS transport giữa các node cũng do ECK quản lý. Đây là cấu hình nền; cần tính dung lượng theo dữ liệu thực tế và cấu hình snapshot trước khi phục vụ dữ liệu production.

## Các file

| File | Vai trò |
| --- | --- |
| `namespace.yaml` | Tạo `elasticsearch` cho cluster và `elastic-system` cho ECK operator. |
| `pv.yaml` | StorageClass `elasticsearch-gp3` cho EBS CSI; PV thật được cấp động. |
| `pvc.yaml` | PVC và Pod **thử storage**, chỉ áp dụng thủ công khi cần kiểm tra. |
| `secret.yaml.example` | Mẫu Secret chứa mật khẩu tài khoản `elastic`. |
| `service-account.yaml` | ServiceAccount `elasticsearch-s3` được EKS Pod Identity ánh xạ tới IAM role snapshot. |
| `elasticsearch.yaml` | Elasticsearch CR 6 node (2 node mỗi AZ); ECK tạo 6 PVC từ `volumeClaimTemplates`. |
| `eck-values.yaml` | 3 replica operator, tách node bằng pod anti-affinity. |

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
- ECK 3.5 hiện hỗ trợ Kubernetes **1.31–1.36**
- EKS dùng **managed EC2 node group thông thường**, không phải EKS Auto Mode. Cần Amazon EBS CSI Driver (`ebs.csi.aws.com`) với IAM permission tạo EBS volume. [Hướng dẫn EBS CSI của AWS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html). Nếu dùng EKS Auto Mode, phải đổi provisioner và cách cài theo [StorageClass cho Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/create-storage-class.html).
- Ít nhất **6 node Ready trong node group `elasticsearch` (label `workload=elasticsearch`), 2 node mỗi AZ trên 3 AZ**. Node group này được khai báo trong [01.nodes.tf](../terraform/01.kubernetes/01.nodes.tf) với `min_size = desired_size = 6`, instance `t3.large`; Kibana cũng chạy trên node group này. Node group `redis` riêng cho Redis và RedisInsight. Áp dụng tầng networking rồi tầng Kubernetes và xác nhận sáu node đã Ready, phân bổ đều ba AZ, trước khi cài. EBS gắn với AZ của PVC; sau sự cố mất AZ, pod dùng PVC cũ không thể tự chuyển sang AZ khác.
- `KUBE_CONTEXT` phải trỏ đúng cluster. Kiểm tra bằng `kubectl config get-contexts` và `kubectl --context "$KUBE_CONTEXT" get nodes -o wide`.
- Init container `sysctl` trong `elasticsearch.yaml` cần quyền `privileged` để đặt `vm.max_map_count=1048576`. Nếu chính sách cluster không cho phép, cấu hình sysctl trên node hoặc qua DaemonSet được quản trị riêng trước khi cài, rồi bỏ init container. [Hướng dẫn Elastic về mmap](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/virtual-memory).
- EKS Pod Identity Agent phải chạy trên các worker node. Terraform đã khai báo add-on này tại [`06.pad-identity-addon.tf`](../terraform/01.kubernetes/06.pad-identity-addon.tf), IAM role/quyền S3 và association cho `elasticsearch/elasticsearch-s3` tại [`13.elasticsearch-backup.tf`](../terraform/01.kubernetes/13.elasticsearch-backup.tf). Áp dụng tầng `terraform/01.kubernetes` trước khi tạo Elasticsearch Pod.
EBS CSI add-on và IAM role dùng Pod Identity được khai báo tại [`terraform/01.kubernetes/09.ebs-csi-driver.tf`](../terraform/01.kubernetes/09.ebs-csi-driver.tf). Áp dụng Terraform trước khi tạo PVC Elasticsearch; nếu dùng hạ tầng khác, cài driver và IAM permission theo [hướng dẫn AWS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html). Nếu pod `Pending` và PVC báo `ExternalProvisioning`, kiểm tra `kubectl get csidriver ebs.csi.aws.com` và pod `ebs-csi-controller` trong `kube-system`.

## Cấu hình kubeconfig

Chạy lệnh sau để thêm context của cluster EKS vào kubeconfig hiện tại trước khi kiểm tra và cài đặt:

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
```

## Kiểm tra trước khi cài

Chạy script preflight từ thư mục gốc repo. Script chỉ đọc Kubernetes API và dừng với mã lỗi nếu cluster chưa đáp ứng phiên bản ECK 3.5, sáu node Ready của node group `elasticsearch` phân bổ trên ba AZ với tối thiểu hai node mỗi AZ, hoặc EBS CSI. Cập nhật dải phiên bản khi đổi phiên bản operator theo [ma trận hỗ trợ ECK](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s).

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
bash elasticsearch/check.sh
```

## Cài operator và Elasticsearch

Chỉ tiếp tục khi khối kiểm tra trên thành công. Chạy các lệnh sau từ thư mục gốc repo. Đặt context chính xác để tránh cài nhầm cluster. Mật khẩu trong `secret.yaml.example` chỉ là mẫu; thay bằng mật khẩu mạnh trong file local và không commit file đó. File `secret.yaml` được bỏ qua bởi `.gitignore`. ECK chấp nhận Secret kiểu `kubernetes.io/basic-auth` làm file realm; tài khoản `elastic` sẽ dùng mật khẩu này.

```bash
set -euo pipefail
cp elasticsearch/secret.yaml.example elasticsearch/secret.yaml
chmod 600 elasticsearch/secret.yaml
${EDITOR:-vi} elasticsearch/secret.yaml

kubectl config get-contexts
export KUBE_CONTEXT="$(kubectl config current-context)"

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

# Tạo Secret xác thực, ServiceAccount dùng Pod Identity, roles và Elasticsearch cluster.
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/secret.yaml

kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/service-account.yaml

kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/role-mapping.yaml

kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/elasticsearch.yaml

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

Không áp dụng `secret.yaml.example` chứa mật khẩu mẫu. Có thể chạy lại lệnh Helm `upgrade --install` sau khi sửa `eck-values.yaml`; sau khi sửa `elasticsearch.yaml`, áp dụng lại manifest bằng `kubectl apply`. Không cài chồng operator khác đang quản lý cùng CRD/namespace nếu chưa kiểm tra quyền sở hữu Helm release.

## Kiểm tra cluster và truy cập

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get elasticsearch search
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pods -l elasticsearch.k8s.elastic.co/cluster-name=search -o wide
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pvc -o wide
kubectl --context "$KUBE_CONTEXT" get pv
kubectl --context "$KUBE_CONTEXT" -n elastic-system get pods -o wide
```

ECK lưu CA công khai tại Secret `search-es-http-certs-public`. Xuất CA để client xác minh chứng chỉ máy chủ; ví dụ kiểm tra qua port-forward (chạy lệnh port-forward ở terminal khác):

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get secret search-es-http-certs-public \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/search-es-ca.crt
kubectl --context "$KUBE_CONTEXT" -n elasticsearch port-forward service/search-es-http 9200:9200

# Terminal khác:
curl --cacert /tmp/search-es-ca.crt \
  --resolve search-es-http.elasticsearch.svc:9200:127.0.0.1 \
  -u elastic https://search-es-http.elasticsearch.svc:9200/

curl -u elastic \
  --cacert /tmp/search-es-ca.crt \
  --resolve search-es-http.elasticsearch.svc:9200:127.0.0.1 \
  https://search-es-http.elasticsearch.svc:9200/_cluster/health?pretty
```

Ứng dụng dùng URL HTTPS cùng CA trên. Không tắt bước xác minh chứng chỉ. [Hướng dẫn ECK về TLS](https://www.elastic.co/docs/deploy-manage/security/eck-tls).

## Tạo index products

Chạy request sau trong Kibana Dev Tools để tạo index `products` với hai primary shard, một replica và các analyzer/field mapping phục vụ tìm kiếm:

```http
PUT /products
{
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 2,
    "analysis": {
      "normalizer": {
        "keyword_normalizer": {
          "type": "custom",
          "filter": ["lowercase", "asciifolding"]
        }
      },
      "filter": {
        "en_stop": {
          "type": "stop",
          "stopwords": "_english_"
        },
        "trigram_filter": {
          "type": "ngram",
          "min_gram": 3,
          "max_gram": 3
        }
      },
      "analyzer": {
        "description_analyzer": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase", "asciifolding", "en_stop"]
        },
        "name_trigram_analyzer": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase", "asciifolding", "trigram_filter"]
        }
      }
    }
  },
  "mappings": {
    "properties": {
      "id": {
        "type": "keyword"
      },
      "name": {
        "type": "text",
        "fields": {
          "keyword": {
            "type": "keyword",
            "ignore_above": 256,
            "normalizer": "keyword_normalizer"
          },
          "autocomplete": {
            "type": "search_as_you_type",
            "max_shingle_size": 3
          },
          "trigram": {
            "type": "text",
            "analyzer": "name_trigram_analyzer",
            "search_analyzer": "name_trigram_analyzer"
          }
        }
      },
      "description": {
        "type": "text",
        "analyzer": "description_analyzer"
      },
      "price": {
        "type": "scaled_float",
        "scaling_factor": 100
      },
      "stock": {
        "type": "integer"
      },
      "createdAt": {
        "type": "date"
      },
      "updatedAt": {
        "type": "date"
      },
      "deletedAt": {
        "type": "date"
      }
    }
  }
}
```

## Tạo nhiều document bằng Bulk API
Dùng `_bulk` API để tạo nhiều document cùng lúc. Mỗi document cần 2 dòng: dòng action và dòng data.
```shell
POST /products/_bulk
{ "index": { "_id": "prod-001" } }
{ "id": "prod-001", "name": "iPhone 15 Pro Max", "description": "Flagship smartphone with titanium design and A17 Pro chip", "price": 29990000, "stock": 50, "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-002" } }
{ "id": "prod-002", "name": "Samsung Galaxy S24 Ultra", "description": "Android flagship with built-in S Pen and 200MP camera", "price": 26990000, "stock": 35, "createdAt": "2024-01-02T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-003" } }
{ "id": "prod-003", "name": "MacBook Pro 14 M3", "description": "Apple laptop with M3 chip, 16GB RAM and 512GB SSD", "price": 49990000, "stock": 20, "createdAt": "2024-01-03T00:00:00Z", "updatedAt": "2024-01-03T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-004" } }
{ "id": "prod-004", "name": "Sony WH-1000XM5 Headphone", "description": "Industry leading noise cancelling wireless headphones", "price": 8990000, "stock": 100, "createdAt": "2024-01-04T00:00:00Z", "updatedAt": "2024-01-04T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-005" } }
{ "id": "prod-005", "name": "iPad Pro 12.9 M2", "description": "Professional tablet with M2 chip and Liquid Retina XDR display", "price": 32990000, "stock": 15, "createdAt": "2024-01-05T00:00:00Z", "updatedAt": "2024-01-05T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-006" } }
{ "id": "prod-006", "name": "Apple Watch Series 9", "description": "Smart watch with health monitoring and carbon neutral design", "price": 12990000, "stock": 60, "createdAt": "2024-01-06T00:00:00Z", "updatedAt": "2024-01-06T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-007" } }
{ "id": "prod-007", "name": "Logitech MX Master 3S Mouse", "description": "Advanced wireless mouse with ultra-fast scrolling and ergonomic design", "price": 2490000, "stock": 200, "createdAt": "2024-01-07T00:00:00Z", "updatedAt": "2024-01-07T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-008" } }
{ "id": "prod-008", "name": "Dell XPS 15 Laptop", "description": "Premium Windows laptop with InfinityEdge display and Intel Core i9", "price": 45990000, "stock": 10, "createdAt": "2024-01-08T00:00:00Z", "updatedAt": "2024-01-08T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-009" } }
{ "id": "prod-009", "name": "AirPods Pro 2nd Generation", "description": "Active noise cancellation earbuds with adaptive transparency", "price": 6490000, "stock": 150, "createdAt": "2024-01-09T00:00:00Z", "updatedAt": "2024-01-09T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-010" } }
{ "id": "prod-010", "name": "Samsung 4K QLED TV 55 inch", "description": "Smart TV with Quantum Dot technology and Neo Quantum Processor", "price": 18990000, "stock": 25, "createdAt": "2024-01-10T00:00:00Z", "updatedAt": "2024-01-10T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-011" } }
{ "id": "prod-011", "name": "Xiaomi Robot Vacuum Cleaner X10", "description": "Smart robot vacuum with laser navigation and 4000Pa suction power", "price": 7990000, "stock": 40, "createdAt": "2024-01-11T00:00:00Z", "updatedAt": "2024-01-11T00:00:00Z", "deletedAt": null }
{ "index": { "_id": "prod-012" } }
{ "id": "prod-012", "name": "Bose QuietComfort 45 Headphone", "description": "Wireless noise cancelling headphones with high-fidelity audio", "price": 7490000, "stock": 0, "createdAt": "2024-01-12T00:00:00Z", "updatedAt": "2024-01-12T00:00:00Z", "deletedAt": "2024-06-01T00:00:00Z" }
```

Kiểm tra số document đã được index:
```shell
GET /products/_count
```

Xem tất cả document (dùng khi debug):
```shell
GET /products/_search
{
  "query": { "match_all": {} },
  "size": 20,
  "sort": [{ "createdAt": "asc" }]
}
```

Xoá documents theo query

```shell
POST /products/_delete_by_query
{
  "query": {
    "match_all": {}
  }
}
```

## Cấu hình Snapshot Repository & SLM qua Kibana Dev Tools

Snapshot trên EBS cần một repository dùng chung, chẳng hạn S3; không dùng thư mục dữ liệu trên PVC của một Elasticsearch pod làm repository. Trước khi chạy API bên dưới:

- Áp dụng [`13.elasticsearch-backup.tf`](../terraform/01.kubernetes/13.elasticsearch-backup.tf). File này tạo IAM role tin cậy `pods.eks.amazonaws.com`, giới hạn trust theo đúng cluster/namespace/ServiceAccount, cấp quyền S3 chỉ dưới prefix `production/search`, rồi tạo `aws_eks_pod_identity_association` cho namespace `elasticsearch` và ServiceAccount `elasticsearch-s3`.
- `elasticsearch.yaml` dùng đúng ServiceAccount trên và **không** còn `spec.secureSettings` cho `access_key`/`secret_key`. EKS tự cấp credential tạm thời và tự xoay vòng; không thêm AWS key vào `elastic-auth` hoặc request Dev Tools.
- Elasticsearch giới hạn file mà repository S3 được đọc. Init container `configure-eks-pod-identity` tạo symlink từ token EKS vào `/usr/share/elasticsearch/config/repository-s3`, trước khi Elasticsearch khởi động. Init container không có biến `ES_PATH_CONF`, nên script dùng đường dẫn config trực tiếp. Manifest đặt cả `AWS_CONTAINER_CREDENTIALS_FULL_URI` và `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` vì EKS xử lý hai biến container credential theo một cặp; không bỏ các biến này hoặc init container.
- Đăng nhập Kibana bằng user có quyền quản lý snapshot repository và SLM (ví dụ `elastic`). Mở **☰ > Management > Dev Tools**. Có thể truy cập Kibana theo [`KIBANA.md`](../kibana/KIBANA.md); không để endpoint hoặc quyền truy cập Kibana public rộng hơn mức cần thiết.

Luồng cấp quyền không chứa khóa dài hạn:

```text
Elasticsearch Pod
  -> ServiceAccount elasticsearch-s3
  -> aws_eks_pod_identity_association
  -> IAM role <cluster>-elasticsearch-snapshot
  -> s3://my-company-es-backups/production/search/*
```

Sau khi Terraform và manifest được áp dụng, ECK sẽ rolling restart các node. Chờ cluster xanh rồi xác nhận Pod mới dùng đúng ServiceAccount và được EKS inject credential provider:

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pods \
  -l elasticsearch.k8s.elastic.co/cluster-name=search \
  -o custom-columns='NAME:.metadata.name,SERVICE_ACCOUNT:.spec.serviceAccountName'

ES_POD="$(kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pods \
  -l elasticsearch.k8s.elastic.co/cluster-name=search \
  -o jsonpath='{.items[0].metadata.name}')"

kubectl --context "$KUBE_CONTEXT" -n elasticsearch exec "$ES_POD" -- sh -c '
  test -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" &&
  test -r "${AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE:-}" &&
  echo "EKS Pod Identity credential provider: OK"
'
```

Không in nội dung token ra terminal. Nếu Pod đã tồn tại từ trước khi association được tạo, áp dụng lại `elasticsearch.yaml` hoặc recreate Pod theo rolling update để admission webhook inject biến môi trường và token volume.

Trong Dev Tools, thay `my-es-snapshots`, `my-company-es-backups` và `us-west-2` bằng tên repository, bucket và region thật. `base_path` tách snapshot của cluster này khỏi các object khác trong bucket:

```http
PUT _snapshot/my-es-snapshots
{
  "type": "s3",
  "settings": {
    "bucket": "my-company-es-backups",
    "region": "ap-southeast-1",
    "base_path": "production/search",
    "compress": true
  }
}
```

Xác minh repository có thể được các node sử dụng:

```http
POST _snapshot/my-es-snapshots/_verify
```

Tạo policy chụp snapshot hằng ngày lúc 01:30 UTC, giữ snapshot tối đa 30 ngày, đồng thời giữ ít nhất 5 và nhiều nhất 50 snapshot:

```http
PUT _slm/policy/daily-search-snapshots
{
  "schedule": "0 30 1 * * ?",
  "name": "<search-snapshot-{now/d}>",
  "repository": "my-es-snapshots",
  "config": {
    "indices": ["*"],
    "ignore_unavailable": true,
    "include_global_state": false
  },
  "retention": {
    "expire_after": "30d",
    "min_count": 5,
    "max_count": 50
  }
}
```

Kiểm tra policy và trạng thái SLM, sau đó chạy thử một snapshot ngay:

```http
GET _slm/policy/daily-search-snapshots
GET _slm/status
PUT _slm/policy/daily-search-snapshots/_execute
GET _snapshot/my-es-snapshots/_all
```

Chỉ xóa snapshot cũ sau khi retention chạy ổn định và đã thử restore. SLM không thay thế việc theo dõi lỗi snapshot; kiểm tra trạng thái policy, lịch chạy và kết quả snapshot định kỳ.

## Restore snapshot qua Kibana Dev Tools

Trước khi restore, xác nhận repository đã đăng ký trên cluster đích và các node truy cập được S3. Cluster đích cần cùng hoặc phiên bản Elasticsearch mới hơn cluster tạo snapshot; không thể restore snapshot vào phiên bản Elasticsearch cũ hơn. Chỉ restore snapshot có trạng thái `SUCCESS`.

Liệt kê snapshot và xem chi tiết snapshot cần khôi phục. Thay `snapshot-name` bằng tên lấy từ kết quả:

```http
GET _snapshot/my-es-snapshots/_all
GET _snapshot/my-es-snapshots/snapshot-name
```

Khuyến nghị restore index sang tên tạm trước để không đụng index đang chạy. Ví dụ khôi phục `products` thành `products-restored`:

```http
POST _snapshot/my-es-snapshots/snapshot-name/_restore
{
  "indices": ["products"],
  "ignore_unavailable": false,
  "include_global_state": false,
  "rename_pattern": "(.+)",
  "rename_replacement": "$1-restored"
}
```

Theo dõi tiến trình và kiểm tra index đã khôi phục:

```http
GET _cat/recovery/products-restored?v
GET _cat/indices/products-restored?v
GET products-restored/_count
GET products-restored/_search
```

So sánh số document và dữ liệu mẫu với snapshot trước khi chuyển ứng dụng sang index đã restore. Restore không ghi đè index đang mở cùng tên. Nếu index gốc không tồn tại và muốn khôi phục trực tiếp đúng tên, bỏ `rename_pattern` và `rename_replacement` khỏi request. Nếu index đã tồn tại, dùng quy trình đóng index bên dưới khi đáp ứng điều kiện về số primary shard. Không xóa index production chỉ để làm cho request restore chạy được.

### Restore vào index `products` với tên cũ

Nếu `products` đã tồn tại và cần khôi phục trực tiếp vào đúng tên này, dừng ghi dữ liệu vào index trước khi restore. Index đích phải được đóng và có cùng số primary shard với `products` trong snapshot; nếu số shard khác nhau, lệnh restore sẽ thất bại. Trong thời gian đóng và khôi phục, ứng dụng không thể đọc/ghi index này. Thay `snapshot-name` bằng tên snapshot đã kiểm tra ở trên, rồi chạy lần lượt trong Dev Tools:

```http
POST /products/_close

POST _snapshot/my-es-snapshots/snapshot-name/_restore
{
  "indices": ["products"],
  "ignore_unavailable": false,
  "include_global_state": false
}
```

Elasticsearch tự mở lại index sau khi restore. Theo dõi quá trình khôi phục và kiểm tra dữ liệu trước khi cho ứng dụng ghi trở lại:

```http
GET _cat/recovery/products?v
GET _cat/indices/products?v
GET products/_count
```

`include_global_state: false` giúp tránh ghi đè cluster settings, template, ingest pipeline và các trạng thái toàn cục của cluster đích. Với khôi phục thảm họa toàn cluster, tạo cluster đích sạch và xác định rõ có cần khôi phục global state hay feature state không; không bật các tùy chọn này trên cluster đang phục vụ traffic nếu chưa đánh giá tác động. Snapshot không thay thế sao lưu cấu hình hạ tầng hoặc kiểm thử quy trình chuyển ứng dụng sang dữ liệu phục hồi.

## Tạo index template mặc định với một replica

Index template này áp dụng cho index mới khớp `*` nếu không có composable template ưu tiên cao hơn. Template chỉ đặt mặc định, không đổi replica cho index đã tồn tại; cấu hình riêng của index hoặc template ứng dụng có thể ghi đè giá trị này.

```http
PUT _index_template/default-one-replica
{
  "index_patterns": ["*"],
  "priority": 0,
  "template": {
    "settings": {
      "number_of_replicas": 1
    }
  }
}
```

Xác minh template và replica của một index mới:

```http
GET _index_template/default-one-replica
PUT replica-template-check
GET replica-template-check/_settings/index.number_of_replicas
DELETE replica-template-check
```


## Lưu ý vận hành

- Elasticsearch 6 node, mọi node là master-eligible nên quorum là 4. Cụm chịu được mất một node, hoặc mất một AZ (2 node), mà vẫn giữ quorum; mất hai AZ thì mất quorum và cụm dừng. Khi mất một AZ, cluster có thể `yellow` trong lúc các bản sao được phân bổ lại; kiểm tra bằng `GET _cluster/health`. Pod anti-affinity yêu cầu mỗi node một pod; khi còn 5 node, pod thứ sáu có thể Pending đến khi node thay thế sẵn sàng. Với HA thực sự, index cần `number_of_replicas >= 1` (template mặc định ở trên đặt 1; zone awareness giúp các bản sao của một shard nằm ở AZ khác nhau).
- EBS volume gắn theo AZ. Pod với PVC đã bound không tự chuyển AZ. Thiết lập snapshot repository trên S3, Snapshot Lifecycle Management (SLM), cảnh báo snapshot lỗi và **thử restore** trước khi đưa dữ liệu production vào. Xem [hướng dẫn cấu hình Snapshot Repository & SLM](#cấu-hình-snapshot-repository--slm-qua-kibana-dev-tools) ở trên và [hướng dẫn snapshot trên ECK](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/cloud-on-k8s). HA không thay thế backup.
- `50Gi` mỗi PVC và `4Gi` RAM/1 vCPU mỗi pod chỉ là cấu hình khởi điểm. Tính dung lượng từ tốc độ ghi, thời gian giữ dữ liệu, số replica, watermark, shard và thời gian phục hồi; tăng PVC trước khi gần đầy. Theo dõi heap, disk, CPU, cluster health và số shard.
- Muốn tăng dung lượng PVC, tăng `storage` trong `elasticsearch.yaml`; không giảm kích thước hoặc đổi StorageClass của PVC đã tạo. [ECK volume claim templates](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/volume-claim-templates).
- Trước khi nâng ECK hoặc Elasticsearch, kiểm tra [tài liệu cài ECK bằng Helm](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/install) và quy trình nâng cấp tương ứng. CRD là tài nguyên toàn cluster; không xóa CRD khi chỉ gỡ một Elasticsearch cluster.

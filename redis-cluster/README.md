# Redis Cluster HA trên EKS

Thư mục này triển khai Redis Cluster gồm **3 master và 3 replica** bằng [OT Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator) **0.27.0**, dùng release `redis-cluster-operator` trong namespace `redis-cluster-system`. Dữ liệu được chia thành 16384 slot cho 3 master; mỗi master có đúng một replica ở AZ khác. Redis, cluster bus và replication đều dùng TLS. Mỗi Pod có một PVC EBS gp3 riêng.

Redis Cluster có sharding: mỗi key thuộc một shard, nên client phải hiểu cluster (ví dụ `redis-cli -c` hoặc cluster client của ngôn ngữ). `app/server.js` dùng client `Cluster` của `ioredis` để kết nối tới cụm này; xem [`../app/README.md`](../app/README.md).

> Thuật ngữ: manifest dùng `leader` và `follower` theo tên trường của CR operator. Tài liệu Redis gọi là `master` và `replica`.

## Các file

| File | Vai trò |
| --- | --- |
| `namespace.yaml` | Tạo namespace `redis-cluster` (tài nguyên của cluster) và `redis-cluster-system` (operator của cluster). |
| `operator-values.yaml` | Release `redis-cluster-operator`: hai replica, chỉ theo dõi namespace `redis-cluster`. Helm cài CRD. |
| `images/redis-cluster/` | Dockerfile và `announce-fqdn.sh`: image node dựa trên `quay.io/opstree/redis:v7.0.15`, entrypoint announce FQDN. |
| `storage-class.yaml` | StorageClass `redis-cluster-gp3` (EBS CSI, `reclaimPolicy: Retain`). |
| `secret.yaml.example` | Mẫu Secret `redis-cluster-auth` chứa khóa `redis-password`. |
| `certificate.yaml` | cert-manager tạo CA `redis-cluster-ca` và Secret `redis-cluster-tls`. |
| `redis-cluster-configmap.yaml` | Bật AOF, giới hạn bộ nhớ, TLS cho replication và cluster bus, endpoint dạng hostname. |
| `redis-cluster.yaml` | `RedisCluster`: 3 leader và 3 follower, PVC và phân bố AZ. |
| `check-cluster.sh` | Kiểm tra trạng thái cluster, số master/replica, label `role` và AZ. |
| `cleanup-ebs-restore.sh` | Xem trước và dọn snapshot, EBS volume cũ cùng PV `Released` sau khi đã xác minh restore. |
| `backup-configmap.yaml` | Script lấy RDB từ từng master, kiểm tra, ghi checksum và upload lên S3. |
| `backup-cronjob.yaml` | ServiceAccount và CronJob backup lúc 01:30 hằng ngày. |
| `images/redis-cluster-backup/` | Dockerfile của image backup chứa `redis-cli`, `redis-check-rdb` và AWS CLI. |
| `images/redis-cluster-restore/` | Dockerfile và script chuyển dữ liệu RDB thành lệnh `RESTORE` cho từng shard. |
| `../terraform/01.kubernetes/15.redis-cluster-backup.tf` | Bucket S3, IAM role và Pod Identity cho backup. |

## Điều kiện

- `kubectl`, `jq`, Helm 3, AWS CLI, Terraform và Docker. Docker dùng để chạy `redis-check-rdb` khi kiểm tra backup.
- Các khối lệnh viết cho **bash 4 trở lên** (`check-cluster.sh` dùng mảng kết hợp). macOS mặc định có bash 3.2; cài bằng `brew install bash` rồi chạy trong `bash`. Các khối có `set -euo pipefail` sẽ đóng terminal khi gặp lỗi, nên có thể đặt trong subshell `( ... )`.
- Cluster EKS dùng managed node group và có Amazon EBS CSI Driver (xem [`09.ebs-csi-driver.tf`](../terraform/01.kubernetes/09.ebs-csi-driver.tf)).
- Cần node group `redis` (label `workload=redis`, Terraform [01.nodes.tf](../terraform/01.kubernetes/01.nodes.tf)) với **ít nhất 6 node Ready, 2 node mỗi AZ trên 3 AZ**, vì mỗi AZ phải có một leader và một follower. Mỗi Redis Pod request 1 GiB RAM, limit 2 GiB. Sáu Pod cần khoảng 6 GiB RAM request và 120 GiB EBS (6 × 20 GiB).
- Tầng `01.kubernetes` đã cài cert-manager.
- Có quyền cài CRD toàn cluster, vì bước 1 cài CRD `redisclusters` qua Helm.

## Tên dịch vụ, TLS và hostname

- Pod: `redis-cluster-leader-{0,1,2}` và `redis-cluster-follower-{0,1,2}`. Service: `redis-cluster-leader`, `redis-cluster-follower` và các Service `-headless` tương ứng. Tên này theo quy ước của operator; xác nhận bằng `kubectl -n redis-cluster get sts,svc,pods`.
- Mỗi node được gọi theo FQDN, ví dụ `redis-cluster-leader-0.redis-cluster-leader-headless.redis-cluster.svc.cluster.local`. Entrypoint của image trong [`images/redis-cluster/`](images/redis-cluster/) đặt `cluster-announce-hostname` thành FQDN đó, thay vì tên Pod ngắn mà image gốc dùng. `cluster-preferred-endpoint-type hostname` làm các chuyển hướng `MOVED` và `CLUSTER SLOTS` trả về FQDN, nhờ đó client từ namespace khác resolve được và xác minh được chứng chỉ.
- Cluster bus là TLS hai chiều: mỗi node vừa là server, vừa là client của node khác. Vì vậy `certificate.yaml` khai báo cả `server auth` lẫn `client auth`. Nếu thiếu `client auth`, các node từ chối kết nối bus với lỗi `certificate verify failed` và cluster không hình thành.
- SAN của `redis-cluster-tls` bao phủ Pod headless (wildcard) và Service của leader, follower. Nếu cluster dùng DNS suffix khác `cluster.local`, sửa `dnsNames` trước khi áp dụng.
- Ứng dụng ở namespace khác không mount được Secret của `redis-cluster`. Copy `ca.crt` vào ConfigMap trong namespace đó, không copy `tls.key`, và không tắt xác minh TLS.

## Cấu hình kubeconfig

Chạy lệnh sau để thêm context của cluster EKS vào kubeconfig hiện tại trước khi kiểm tra và cài đặt:

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
```

## Cài đặt

Chạy từ root repository.

### 1. Operator riêng cho Redis Cluster

Release `redis-cluster-operator` chạy trong namespace `redis-cluster-system`, chỉ theo dõi namespace `redis-cluster` (xem `operator-values.yaml`). Helm cài cả CRD từ chart, nên release này sở hữu CRD `redisclusters.redis.redis.opstreelabs.in`.

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"

kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/namespace.yaml

helm --kube-context "$KUBE_CONTEXT" upgrade --install redis-cluster-operator \
  oci://ghcr.io/ot-container-kit/charts/redis-operator \
  --version 0.27.0 --namespace redis-cluster-system \
  -f redis-cluster/operator-values.yaml --wait --timeout 10m

kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/redisclusters.redis.redis.opstreelabs.in --timeout=120s

kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system rollout status deploy/redis-cluster-operator --timeout=3m
```

Helm không cập nhật CRD khi `helm upgrade`. Khi nâng cấp chart, chạy `kubectl apply --server-side` với CRD trong `crds/` của chart phiên bản mới trước, rồi mới upgrade release.

### 2. StorageClass và TLS

```bash
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/storage-class.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/certificate.yaml

kubectl --context "$KUBE_CONTEXT" -n redis-cluster wait --for=condition=Ready \
  issuer/redis-cluster-selfsigned certificate/redis-cluster-ca \
  issuer/redis-cluster-ca certificate/redis-cluster-tls --timeout=5m
```

### 3. Mật khẩu, cấu hình và CR

`redis-cluster.yaml` dùng image node riêng, build từ [`images/redis-cluster/`](images/redis-cluster/) trên `quay.io/opstree/redis:v7.0.15`. Entrypoint của image gốc announce tên Pod ngắn, nên image này patch để announce FQDN. Có thể build image trước hoặc sau khi cài operator, nhưng phải push **trước khi apply CR** (tag dưới đây khớp với `kubernetesConfig.image`):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t thoaiky1992/redis-cluster:7.0.15-fqdn.1 --push redis-cluster/images/redis-cluster
```

Tạo mật khẩu mạnh trong `secret.yaml`. File này nằm trong `.gitignore`, không commit.

```bash
cp redis-cluster/secret.yaml.example redis-cluster/secret.yaml
chmod 600 redis-cluster/secret.yaml
${EDITOR:-vi} redis-cluster/secret.yaml

kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/redis-cluster-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/redis-cluster.yaml
```

Sau khi các Pod chạy, kiểm tra node đã announce FQDN và Pod có `POD_NAMESPACE`. Nếu `POD_NAMESPACE` rỗng, Pod thoát với `POD_NAMESPACE is required`; khi đó operator không truyền `valueFrom` của `spec.env`, cần xử lý trước khi tiếp tục:

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-cluster exec redis-cluster-leader-0 -- printenv POD_NAMESPACE

RPW="$(kubectl --context "$KUBE_CONTEXT" -n redis-cluster get secret redis-cluster-auth \
  -o jsonpath='{.data.redis-password}' | base64 --decode)"

kubectl --context "$KUBE_CONTEXT" -n redis-cluster exec redis-cluster-leader-0 -- \
  env REDISCLI_AUTH="$RPW" redis-cli --tls --cacert /tls/ca.crt \
  --sni redis-cluster-leader.redis-cluster.svc.cluster.local \
  -h redis-cluster-leader.redis-cluster.svc.cluster.local -p 6379 --raw CLUSTER NODES | awk '{print $2}'
  
unset RPW
```

Mọi dòng phải có dạng `<ip>:6379@16379,<tên-pod>.<tên-pod-headless>.redis-cluster.svc.cluster.local`. Nếu còn tên ngắn, ảnh chưa được dùng: kiểm tra `kubectl -n redis-cluster get pods -o jsonpath='{.items[0].spec.containers[0].image}'`.

Chờ sáu Pod Ready. Nếu lệnh báo `no matching resources found`, đợi vài giây rồi chạy lại vì operator chưa tạo Pod.

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-cluster wait --for=condition=Ready \
  pod -l role=leader --timeout=15m

kubectl --context "$KUBE_CONTEXT" -n redis-cluster wait --for=condition=Ready \
  pod -l role=follower --timeout=15m
```

Sau khi các Pod Ready, operator tạo cluster. Kiểm tra bằng script trong phần dưới. Nếu `cluster_state` chưa `ok` sau vài phút, xem log operator:

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system logs deploy/redis-cluster-operator --tail=100
```

## Kiểm tra

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-cluster get rediscluster redis-cluster
kubectl --context "$KUBE_CONTEXT" -n redis-cluster get pods,pvc,svc -o wide --show-labels

KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh
```

`check-cluster.sh` kiểm tra theo thứ tự:

- `cluster_state:ok`, đủ 6 node và 16384 slot.
- Có đủ 3 Pod với label `role=leader` và 3 Pod với `role=follower`. Affinity dựa trên label này; nếu không khớp, phân bố AZ sẽ không được ràng buộc.
- Mỗi master có đúng một replica. Không có hai master nào cùng AZ.

Kết quả `FAIL` làm script thoát với mã khác 0. Kết quả `WARN` (master và replica cùng AZ) không làm script thất bại, nhưng xem phần dưới.

## Phân bố AZ và giới hạn

Affinity bắt buộc các leader nằm ở ba AZ khác nhau, và các follower cũng vậy. Operator không kiểm soát việc ghép cặp master với replica, nên một follower vẫn có thể nằm cùng AZ với master mà nó sao chép. Với ba AZ, khi một AZ mất và cả master lẫn replica của một shard cùng nằm trong AZ đó, shard này mất cả hai. Vì `cluster-require-full-coverage yes` là mặc định, toàn bộ cluster sẽ ngừng nhận lệnh cho đến khi có master cho shard đó.

Nếu muốn các shard còn lại vẫn phục vụ trong tình huống này, đổi `cluster-require-full-coverage` thành `no` trong ConfigMap. Đổi lại, client sẽ nhận lỗi với các slot của shard đã mất. Đây là quyết định về độ sẵn sàng và cần được chấp nhận rõ ràng.

## Kết nối từ ứng dụng

Client phải hỗ trợ cluster và TLS. Ví dụ với `redis-cli` từ Pod trong cluster:

```bash
redis-cli -c --tls --cacert /etc/ca/ca.crt \
  --sni redis-cluster-leader.redis-cluster.svc.cluster.local \
  -h redis-cluster-leader.redis-cluster.svc.cluster.local -p 6379 \
  --no-auth-warning -a "$REDIS_PASSWORD"
```

Đừng bỏ `--cacert` hoặc thêm `--insecure` để kết nối được. Client phải tin cậy `ca.crt` của `redis-cluster-tls`.

## Backup lên AWS S3

Backup gồm một RDB cho mỗi master, lấy từ topology hiện tại (`CLUSTER NODES`), nên không phụ thuộc Pod nào đang là master. Mỗi RDB được kiểm tra bằng `redis-check-rdb` trước khi upload.

Điều kiện trước khi chạy:

- Cluster ở `cluster_state:ok` và đủ 6 Pod Ready.
- Cả 6 node announce FQDN (image `thoaiky1992/redis-cluster:7.0.15-fqdn.1`). Script kết nối tới hostname lấy từ `CLUSTER NODES`; nếu còn tên Pod ngắn, script không kết nối được.
- Image `thoaiky1992/redis-cluster-backup:1.0.0` phải pull được ẩn danh, vì CronJob không có pull secret.

```text
s3://<bucket>/redis-cluster/<UTC-timestamp>/
├── cluster-nodes.txt
├── metadata.json      # created_at, số shard kỳ vọng, node_id, host, dải slot và số key của từng shard
├── SHA256SUMS
├── shard-01/dump.rdb  # master giữ slot 0-5460
├── shard-02/dump.rdb  # master giữ slot 5461-10922
├── shard-03/dump.rdb  # master giữ slot 10923-16383
└── _SUCCESS           # upload sau cùng; restore phải bỏ qua prefix thiếu file này
```

Lưu ý khi dùng bản backup:

- Mỗi RDB được lấy ở thời điểm khác nhau, cách nhau vài giây. Từng shard nhất quán, nhưng không có ảnh chụp chung cho cả cluster.
- AOF trên PVC không thay thế backup.

### 1. Tạo bucket và quyền bằng Terraform

Đặt tên bucket duy nhất toàn cục trong `terraform/01.kubernetes/terraform.tfvars`. Nếu bỏ qua, mặc định là `dev-demo-redis-cluster-backup`, và tên này có thể đã bị dùng.

```hcl
redis_cluster_backup_bucket_name    = "<tên-bucket-duy-nhất>"
redis_cluster_backup_retention_days = 30
```

File `15.redis-cluster-backup.tf` tạo bucket private, bật versioning, mã hóa SSE-S3, lifecycle theo prefix `redis-cluster/`, IAM role chỉ có quyền trên prefix đó và EKS Pod Identity cho ServiceAccount `dev-demo-redis-cluster-backup` trong namespace `redis-cluster`. CronJob không cần Access Key nào.

```bash
terraform -chdir=terraform/01.kubernetes plan -var-file=terraform.tfvars
terraform -chdir=terraform/01.kubernetes apply -var-file=terraform.tfvars

export S3_BUCKET="$(terraform -chdir=terraform/01.kubernetes output -json values | \
  jq -r '.redis_cluster_backup.bucket_name')"
test -n "$S3_BUCKET" && test "$S3_BUCKET" != null
```

### 2. Image backup

CronJob và khối restore dùng image `thoaiky1992/redis-cluster-backup:1.0.0`. Image gồm `redis-cli`, `redis-check-rdb` và AWS CLI, được build từ [`images/redis-cluster-backup/Dockerfile`](images/redis-cluster-backup/Dockerfile). Build và push image trước khi chạy CronJob:

```bash
export BACKUP_IMAGE="thoaiky1992/redis-cluster-backup:1.0.0"

docker buildx build --platform linux/amd64,linux/arm64 \
  -f redis-cluster/images/redis-cluster-backup/Dockerfile \
  -t "$BACKUP_IMAGE" --push redis-cluster/images/redis-cluster-backup
```

Nếu đổi `BACKUP_IMAGE`, sửa image trong `backup-cronjob.yaml` và các lệnh `docker run` trong khối restore cho khớp.

### 3. Cấu hình và cài CronJob

Trước khi apply, sửa `S3_BUCKET` trong `backup-configmap.yaml` thành giá trị của `$S3_BUCKET` ở trên. Không commit tên bucket thật vào repo. `AWS_REGION` nằm trong `backup-cronjob.yaml`, mặc định `ap-southeast-1`.

```bash
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/backup-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/backup-cronjob.yaml
kubectl --context "$KUBE_CONTEXT" -n redis-cluster get cronjob dev-demo-redis-cluster-backup
```

CronJob chạy lúc **01:30 giờ Việt Nam** (`schedule: "30 1 * * *"`, `timeZone: Asia/Ho_Chi_Minh`). `concurrencyPolicy: Forbid` ngăn hai lần backup chạy chồng nhau.

Chạy thử ngay, xem log và xác nhận object trên S3:

```bash
JOB="dev-demo-redis-cluster-backup-manual-$(date +%s)"

kubectl --context "$KUBE_CONTEXT" -n redis-cluster create job \
  --from=cronjob/dev-demo-redis-cluster-backup "$JOB"

kubectl --context "$KUBE_CONTEXT" -n redis-cluster wait \
  --for=condition=Complete "job/$JOB" --timeout=2h

kubectl --context "$KUBE_CONTEXT" -n redis-cluster logs "job/$JOB"

aws s3 ls "s3://$S3_BUCKET/redis-cluster/" --recursive
```

Job thành công khi log kết thúc bằng `Backup uploaded successfully: s3://<bucket>/redis-cluster/<UTC-timestamp>/`. Dòng `keys=` của mỗi shard là số key theo `redis-check-rdb`; `keys=0` là đúng khi cluster chưa có dữ liệu.

Backup lấy RDB từ master bằng replication, nên mỗi master tạo một fork. Kiểm tra bộ nhớ node trước khi dataset lớn.

### Vận hành backup cho production

- CronJob chạy lúc 01:30 giờ Việt Nam, ngoài giờ cao điểm. Backup lấy RDB bằng fork trên master, nên kiểm tra bộ nhớ node trước khi dataset tăng lớn.
- Theo dõi job thất bại. CronJob giữ 3 job `Failed` gần nhất (`failedJobsHistoryLimit: 3`); gắn cảnh báo khi có job `Failed` trong ngày.
- Kiểm thử restore định kỳ (ví dụ hằng tháng) trên staging bằng bản backup mới nhất có `_SUCCESS`. Bản backup chưa từng được restore thử không được coi là bản khôi phục đáng tin.
- Bucket đã bật versioning, mã hoá SSE-S3 và lifecycle 30 ngày theo Terraform. Không xoá prefix backup khi chưa có bản backup mới hơn đã kiểm chứng.

### Sự cố khi backup

- **`Could not connect to Redis at redis-cluster-leader-0:6379: Name or service not known`.** Một node vẫn announce tên Pod ngắn, tức là chưa dùng image FQDN. Kiểm tra `CLUSTER NODES` theo mục "Cài đặt" và đảm bảo cả 6 Pod đã rollout xong.
- **`Cluster chưa ở trạng thái ok`.** Đợi failover hoặc rollout xong rồi chạy lại.
- **`Tìm thấy N master, kỳ vọng 3`.** Có node đang `fail` hoặc topology không đủ 3 master. Xem `CLUSTER NODES`.
- **`Failed to pull image ... insufficient_scope`.** Repo image chưa public trên Docker Hub.
- **Job `Failed` nhưng không còn log.** Pod bị xóa sau khi vượt `backoffLimit`. Theo dõi log khi job đang chạy: `kubectl -n redis-cluster logs -f job/<job>`.

## Restore từ S3

Restore **ghi dữ liệu từ bản backup vào cluster đang chạy**. Thực hiện ngoài giờ cao điểm, dừng ghi từ ứng dụng, và thử trên staging trước.

Quy trình nạp từng key bằng lệnh `RESTORE` qua pipe vào master hiện tại. Dữ liệu được nhân bản sang replica như các lệnh ghi thông thường.

### Điều kiện trước khi restore

- Cluster `cluster_state:ok`, đủ 6 node, không có node nào có cờ `fail` hoặc link `disconnected`.
- Operator không đang trong vòng sửa lỗi (xem bước 2).
- AOF bật (`appendonly yes`) trên tất cả node để dữ liệu bền sau khi Pod khởi động lại. Nếu đang `appendonly no`, chạy `kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/redis-cluster-configmap.yaml` rồi `CONFIG SET appendonly yes` trên từng Pod, chờ `aof_rewrite_in_progress:0`.
- Khuyến nghị tạo bộ snapshot EBS của cả PVC dữ liệu và `node-conf` cho sáu Pod ngay trước khi restore từ S3 (bước 3) để có điểm quay lại. Nếu bỏ qua, cần một phương án rollback khác đã được kiểm thử.
- Máy quản trị có `aws`, `docker`, `jq`, `kubectl` và quyền đọc S3 của bucket backup. Python và thư viện `redis` chạy trong image restore, không cần cài trên máy quản trị.
- Với shard lớn, kiểm tra dung lượng trống trên máy quản trị và bộ nhớ Docker: quy trình giữ RDB tải từ S3, bản sao RDB để Redis nguồn nạp và file RESP cùng lúc. RDB có thể nén tốt hơn nhiều so với dữ liệu trong RAM/file RESP. Master đích đang cấu hình `maxmemory 1gb`, Pod giới hạn 2 GiB RAM; không dựa vào kích thước RDB để kết luận đủ bộ nhớ.
- `RESTORE ... REPLACE` chỉ thay các key có trong backup; key khác đang tồn tại trên cluster đích sẽ còn nguyên. TTL hiện được tính lúc tạo file RESP và bắt đầu đếm lại khi nạp, nên key có thể hết hạn muộn hơn khoảng thời gian chờ giữa hai bước; với bản restore lớn cần tính đến sai lệch này.

### Image chuyển đổi dữ liệu cho restore

Build image riêng trên máy quản trị trước khi restore. Image chỉ chứa script chuyển đổi và thư viện Python; dữ liệu backup không được đóng vào image. Khi đổi script hoặc Dockerfile, build lại image.

```bash
export RESTORE_IMAGE=redis-cluster-restore:1.0.0
docker build -f redis-cluster/images/redis-cluster-restore/Dockerfile -t "$RESTORE_IMAGE" redis-cluster/images/redis-cluster-restore
```

### 1. Biến và xác minh bản backup

```bash
set -euo pipefail
export KUBE_CONTEXT="$(kubectl config current-context)"
export NAMESPACE=redis-cluster
export AWS_REGION=ap-southeast-1
export S3_BUCKET="$(terraform -chdir=terraform/01.kubernetes output -json values | \
  jq -r '.redis_cluster_backup.bucket_name')"
export BACKUP_TIMESTAMP="${BACKUP_TIMESTAMP:-}"   # bắt buộc, ví dụ 20261029T150024Z (xem `aws s3 ls`)
: "${S3_BUCKET:?S3_BUCKET chưa đặt}"
: "${BACKUP_TIMESTAMP:?BACKUP_TIMESTAMP chưa đặt}"

export RESTORE_DIR="/tmp/redis-cluster/restore/$BACKUP_TIMESTAMP"   # chứa dữ liệu thật; xoá sau khi xong
mkdir -p "$RESTORE_DIR"
aws s3 sync "s3://$S3_BUCKET/redis-cluster/$BACKUP_TIMESTAMP/" "$RESTORE_DIR/"
test -s "$RESTORE_DIR/_SUCCESS"
(cd "$RESTORE_DIR" && shasum -a 256 -c SHA256SUMS)   # Linux: sha256sum -c SHA256SUMS
du -sh "$RESTORE_DIR"
df -h "$RESTORE_DIR"

for DIR in "$RESTORE_DIR"/shard-*; do
  NAME="$(basename "$DIR")"
  OUT="$(docker run --rm -v "$RESTORE_DIR:/b:ro" --entrypoint redis-check-rdb \
    thoaiky1992/redis-cluster-backup:1.0.0 "/b/$NAME/dump.rdb" 2>&1)"
  grep -q 'RDB looks OK' <<<"$OUT"
  echo "$NAME: $(awk '/keys read/{print $2}' <<<"$OUT") key"
done

jq -r '.shards[] | [.name, .host, .slots, .keys] | @tsv' "$RESTORE_DIR/metadata.json"
```

### 2. Kiểm tra cluster trước khi ghi

Hàm `rcli` chạy `redis-cli` trong Pod. Operator đã đặt sẵn `REDISCLI_AUTH` trong Pod, nên không cần truyền mật khẩu trên dòng lệnh.

```bash
pod_host() { # tên Pod -> FQDN của Pod trong headless Service
  local role="${1%-*}"
  echo "$1.${role}-headless.${NAMESPACE}.svc.cluster.local"
}

rcli() { # rcli <pod> <lệnh redis-cli>
  local pod="$1"; shift
  local h; h="$(pod_host "$pod")"
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" exec "$pod" -- \
    redis-cli --tls --cacert /tls/ca.crt --sni "$h" -h "$h" -p 6379 "$@"
}

rcli redis-cluster-leader-0 CLUSTER INFO | tr -d '\r' | grep -q '^cluster_state:ok'

# Không node nào có cờ fail hoặc link disconnected. Lệnh này phải không in ra gì.
rcli redis-cluster-leader-0 CLUSTER NODES | tr -d '\r' | awk '$3 ~ /(^|,)fail/ || $8 != "connected"'

# Operator không đang sửa lỗi trong 5 phút gần nhất.
REPAIRS="$(kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system logs deploy/redis-cluster-operator --since=5m \
  | { grep -c 'attempting to repair' || true; })"
echo "Số lần operator thử sửa lỗi: $REPAIRS"
test "$REPAIRS" = 0

for POD in redis-cluster-leader-0 redis-cluster-leader-1 redis-cluster-leader-2 \
           redis-cluster-follower-0 redis-cluster-follower-1 redis-cluster-follower-2; do
  rcli "$POD" CONFIG GET appendonly | tail -1 | grep -qx yes
done
```

Nếu bước nào không đạt, dừng và xử lý trước. Không restore khi operator đang sửa lỗi.

### 3. Snapshot EBS (khuyến nghị)

Snapshot EBS là bản sao **volume**, khác với snapshot repository ở tầng ứng dụng của [Elasticsearch](../elasticsearch/ELASTICSEARCH.md). Với Redis Cluster này, mỗi Pod có PVC `/data` (AOF/RDB) và PVC `/node-conf` (node ID và membership). Muốn khôi phục nguyên cluster từ EBS, chụp **cả 12 PVC** cùng một bộ; chỉ chụp sáu PVC `/data` không đủ để khôi phục membership. Các lệnh dưới đây tạo một bộ snapshot offline làm điểm quay lại trước khi nạp dữ liệu từ S3. [AWS khuyến nghị dừng ghi để snapshot nhất quán](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-creating-snapshot.html); các snapshot tạo lần lượt trên nhiều EC2 node không phải một giao dịch nguyên tử.

Dừng toàn bộ traffic ghi từ ứng dụng và xác nhận cluster khỏe theo bước 2. Khối lệnh tạm dừng operator và sáu Redis Pod, tạo snapshot khi volume không còn được ghi, rồi chạy lại workload **ngay sau khi đã gửi đủ lệnh tạo snapshot**. Nếu một lệnh lỗi, `trap` vẫn thử khởi động lại workload. Chạy trong Bash hoặc zsh từ root repo; lưu `volumes.tsv` ngoài repo vì đó là bản đồ PVC/PV/volume/snapshot bắt buộc cho restore. Cần quyền AWS `ec2:CreateSnapshot`, `ec2:DescribeSnapshots`, `ec2:DescribeVolumes`; kiểm tra `kubectl config current-context` và tài khoản AWS trước khi chạy.

```bash
rm -r /tmp/redis-cluster

export SNAP_TS="$(date -u +%Y%m%dT%H%M%SZ)"   # tạo một lần; thư mục snapshot và thư mục restore đều dùng giá trị này
(
  set -euo pipefail
  SNAP_DIR="/tmp/redis-cluster/snapshots/$SNAP_TS"
  mkdir -p "$SNAP_DIR"
  SNAP_MAP="$SNAP_DIR/volumes.tsv"
  : > "$SNAP_MAP"
  echo "Bản đồ snapshot: $SNAP_MAP"
  OP_REPLICAS="$(kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system get deploy redis-cluster-operator -o jsonpath='{.spec.replicas}')"
  LEADER_REPLICAS="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get sts redis-cluster-leader -o jsonpath='{.spec.replicas}')"
  FOLLOWER_REPLICAS="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get sts redis-cluster-follower -o jsonpath='{.spec.replicas}')"
  for STS in redis-cluster-leader redis-cluster-follower; do
    test "$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get sts "$STS" \
      -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy.whenScaled}')" = Retain
  done
  resume_cluster() {
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-cluster-leader --replicas="$LEADER_REPLICAS"
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-cluster-follower --replicas="$FOLLOWER_REPLICAS"
    kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system scale deploy/redis-cluster-operator --replicas="$OP_REPLICAS"
  }
  trap resume_cluster EXIT
  kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system scale deploy/redis-cluster-operator --replicas=0
  kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system wait --for=delete pod -l name=redis-cluster-operator --timeout=3m
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-cluster-leader sts/redis-cluster-follower --replicas=0

  for POD in redis-cluster-leader-{0..2} redis-cluster-follower-{0..2}; do
    kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=delete "pod/$POD" --timeout=5m
    for KIND in data nodeconf; do
      if [[ "$KIND" == data ]]; then PVC="${POD%-*}-${POD}"; else PVC="node-conf-$POD"; fi
      PV="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')"
      test "$(kubectl --context "$KUBE_CONTEXT" get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain
      VOL="$(kubectl --context "$KUBE_CONTEXT" get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')"
      read -r AZ SIZE_GIB < <(aws ec2 describe-volumes --region "$AWS_REGION" --volume-ids "$VOL" \
        --query 'Volumes[0].[AvailabilityZone,Size]' --output text)
      SNAP="$(aws ec2 create-snapshot --region "$AWS_REGION" --volume-id "$VOL" \
        --description "redis-cluster $SNAP_TS $PVC" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=BackupSet,Value=$SNAP_TS},{Key=PVC,Value=$PVC}]" \
        --query SnapshotId --output text)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$POD" "$KIND" "$PVC" "$PV" "$VOL" "$AZ" "$SIZE_GIB" "$SNAP" >> "$SNAP_MAP"
    done
  done
  test "$(wc -l < "$SNAP_MAP" | tr -d ' ')" -eq 12
  resume_cluster
  trap - EXIT
  SNAP_IDS=()
  while IFS= read -r SNAP_ID; do SNAP_IDS+=("$SNAP_ID"); done < <(cut -f8 "$SNAP_MAP")
  aws ec2 wait snapshot-completed --region "$AWS_REGION" --snapshot-ids "${SNAP_IDS[@]}"
  echo "Bộ snapshot $SNAP_TS hoàn tất; giữ bản đồ: $SNAP_MAP"
)
```

Sau đó kiểm tra sáu Pod Ready, `KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh`, và lưu bản đồ `volumes.tsv` ở nơi bền vững, có kiểm soát truy cập. Snapshot giữ trạng thái tại thời điểm tạo; không chứa các ghi sau đó. Xem [quy trình khôi phục nguyên cluster từ EBS snapshot](#khôi-phục-nguyên-cluster-từ-ebs-snapshot) bên dưới. Backup RDB trên S3 vẫn là đường khôi phục dữ liệu chính. Muốn bảo vệ trước sự cố mất cả Region, sao chép snapshot hoặc backup sang Region khác.

Nếu shell dừng **sau khi đã tạo snapshot**, không chạy lại phần tạo snapshot. Dùng `volumes.tsv` đã lưu để chờ và xác nhận bộ snapshot hiện có (chạy được trong Bash hoặc zsh):

```bash
export SNAP_TS=<SNAP_TS>   # đúng giá trị đã in ra ở bước snapshot, không tạo mới
SNAP_MAP="/tmp/redis-cluster/snapshots/$SNAP_TS/volumes.tsv"
AWS_REGION=ap-southeast-1
SNAP_IDS=()
while IFS= read -r SNAP_ID; do SNAP_IDS+=("$SNAP_ID"); done < <(cut -f8 "$SNAP_MAP")
test "${#SNAP_IDS[@]}" -eq 12
aws ec2 wait snapshot-completed --region "$AWS_REGION" --snapshot-ids "${SNAP_IDS[@]}"
echo "Đã hoàn tất: $SNAP_MAP"
```

### 4. Tạo lệnh RESTORE cho từng shard

Dùng đúng phiên bản Redis của cluster (`7.0.15`) để đọc `dump.rdb`, rồi xuất từng key thành lệnh `RESTORE` có giữ TTL. Script [`images/redis-cluster-restore/dump_to_resp.py`](images/redis-cluster-restore/dump_to_resp.py) chạy trong image restore và chỉ đọc nguồn. Container chuyển đổi dùng chung network namespace với Redis nguồn; không cần mở cổng trên máy quản trị.

```bash
for DIR in "$RESTORE_DIR"/shard-*; do
  NAME="$(basename "$DIR")"
  SRC="$RESTORE_DIR/src-$NAME"
  mkdir -p "$SRC" && cp "$DIR/dump.rdb" "$SRC/dump.rdb"
  docker rm -f "restore-src" >/dev/null 2>&1 || true
  docker run -d --name "restore-src" -v "$SRC:/data" \
    redis:7.0.15-bookworm redis-server --dir /data --dbfilename dump.rdb --appendonly no >/dev/null
  until docker exec restore-src redis-cli ping 2>/dev/null | grep -q PONG; do sleep 1; done

  docker run --rm --read-only --network container:restore-src "$RESTORE_IMAGE" \
    127.0.0.1 6379 > "$RESTORE_DIR/$NAME.resp" 2> "$RESTORE_DIR/$NAME.convert.log"
  EXPECTED="$(jq -r --arg n "$NAME" '.shards[] | select(.name==$n) | .keys' "$RESTORE_DIR/metadata.json")"
  SOURCE_KEYS="$(docker exec restore-src redis-cli DBSIZE)"
  CONVERTED="$(sed -n 's/^written=\([0-9][0-9]*\) skipped_expired=.*/\1/p' "$RESTORE_DIR/$NAME.convert.log")"
  echo "$NAME: nguồn DBSIZE=$SOURCE_KEYS, lệnh RESTORE=$CONVERTED, metadata keys=$EXPECTED"
  test "$SOURCE_KEYS" = "$EXPECTED" && test "$CONVERTED" = "$EXPECTED"
  # Nếu lệch, dừng: key đã hết hạn, bản backup không khớp hoặc chuyển đổi thiếu key.

  docker rm -f restore-src >/dev/null
done
```

Nếu số key nguồn hoặc số lệnh `RESTORE` lệch với `keys` trong metadata, dừng lại và kiểm tra. Key hết hạn giữa lúc backup và lúc restore sẽ bị bỏ qua và làm số đếm thấp hơn. Kiểm tra dung lượng trống lần nữa trước khi gửi file RESP; ba shard được xử lý tuần tự và các file RESP vẫn nằm trong `$RESTORE_DIR`.

### 5. Ghi vào master hiện tại của từng shard

Xác định master theo dải slot tại thời điểm chạy, không dùng tên Pod cố định. Master có thể đã đổi sau failover.

```bash
master_for_range() { # master_for_range <dải slot>, ví dụ 5461-10922
  rcli redis-cluster-leader-0 CLUSTER NODES | tr -d '\r' | awk -v s="$1" '
    $3 ~ /master/ && $3 !~ /(^|,)fail/ {
      split($2, a, ","); split(a[2], h, ".")
      r = ""; for (i = 9; i <= NF; i++) r = r " " $i
      sub(/^ /, "", r)
      if (r == s) print h[1]
    }'
}

while IFS=$'\t' read -r NAME SLOTS; do
  POD="$(master_for_range "$SLOTS")"
  test -n "$POD"
  H="$(pod_host "$POD")"
  RESULT="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" exec -i "$POD" -- \
    redis-cli --tls --cacert /tls/ca.crt --sni "$H" -h "$H" -p 6379 --pipe \
    < "$RESTORE_DIR/$NAME.resp" 2>&1)"
  echo "$RESULT" | tail -1
  grep -q 'errors: 0' <<<"$RESULT"
done < <(jq -r '.shards[] | [.name, .slots] | @tsv' "$RESTORE_DIR/metadata.json")
```

`errors: 0` là điều kiện để đi tiếp. Nếu có lỗi (ví dụ `MOVED`), dừng và kiểm tra ánh xạ slot. Không chạy lại mà chưa hiểu nguyên nhân.

### 6. Kiểm tra dữ liệu và replica

Chờ replica đồng bộ rồi so sánh `DBSIZE` trên master và trên từng replica.

```bash
for POD in redis-cluster-leader-0 redis-cluster-leader-1 redis-cluster-leader-2 \
           redis-cluster-follower-0 redis-cluster-follower-1 redis-cluster-follower-2; do
  echo "$POD $(rcli "$POD" INFO replication | tr -d '\r' | grep -E '^role|^master_link_status' | tr '\n' ' ') DBSIZE=$(rcli "$POD" DBSIZE | tr -d '\r')"
done

KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh
```

Mỗi master phải có `DBSIZE` bằng `keys` của shard. Mỗi replica của master đó phải có `master_link_status:up` và `DBSIZE` bằng master. Nếu replica chưa khớp, đợi thêm và kiểm tra lại.

### 7. Sau restore

- Chạy backup mới ngay (xem mục Backup) để có điểm khôi phục sạch.
- Mở lại traffic ghi sau khi ứng dụng kết nối lại được.
- Xoá thư mục chứa dữ liệu thật: `rm -rf "$RESTORE_DIR"`.
- Giữ snapshot ở bước 3 cho đến khi xác nhận ổn định.

### Sự cố thường gặp

- **`errors:` khác 0 khi pipe.** Thường do ghi vào node không sở hữu slot của key. Kiểm tra lại `master_for_range` và dải slot trong metadata.
- **Replica không sync sau khi ghi.** Kiểm tra `master_link_status`, `CLUSTER NODES` có cờ `fail` không, và log replica.
- **`DBSIZE` thấp hơn `keys` trong metadata.** Key đã hết hạn lúc restore. Kiểm tra bằng `redis-check-rdb` trên `dump.rdb`.

## Khôi phục nguyên cluster từ EBS snapshot

Quy trình này thay **toàn bộ 12 PVC** của chính cluster đã tạo snapshot, đưa dữ liệu và `nodes.conf` về cùng bộ snapshot. Đây là thao tác có thời gian ngừng dịch vụ và làm mất mọi ghi sau thời điểm snapshot. Thử trên staging trước; không dùng một vài snapshot lẻ, không ghép snapshot từ các thời điểm khác nhau, và không cho ứng dụng ghi trong lúc khôi phục. Giữ nguyên RedisCluster CR, namespace, tên Pod, cấu hình TLS và số node. Nếu mục tiêu là nạp dữ liệu vào cluster mới, dùng [restore từ S3](#restore-từ-s3) thay vì sao chép `nodes.conf` của cluster cũ.

EBS tạo volume mới từ snapshot; volume phải nằm trong AZ có node sẽ chạy Pod. EBS CSI có thể dùng volume có sẵn qua PV tĩnh với `csi.volumeHandle` và `nodeAffinity` ([AWS](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-creating-volume.html), [EBS CSI static provisioning](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/examples/kubernetes/static-provisioning/README.md)). Không sửa `volumeHandle` trên PV cũ và không xóa EBS volume cũ; `Retain` giữ chúng làm đường quay lại.

### 1. Tạo volume mới và manifest PV/PVC

Chạy trong Bash từ root repo. Thay `SNAP_MAP` bằng file `volumes.tsv` đã lưu ở bước snapshot và xác nhận đúng cluster, Region, tài khoản AWS. Cần quyền `ec2:DescribeSnapshots`, `ec2:CreateVolume`, `ec2:DescribeVolumes`. Tạo trước 12 volume mới để giảm thời gian ngừng dịch vụ; chưa thay PVC đang chạy ở bước này. File manifest tạo ra phải được kiểm tra trước khi áp dụng.

```bash
set -euo pipefail
export KUBE_CONTEXT="$(kubectl config current-context)"
export NAMESPACE=redis-cluster
export AWS_REGION=ap-southeast-1
export SNAP_TS=<SNAP_TS>   # đúng giá trị đã in ra ở bước snapshot, không tạo mới
export SNAP_MAP="/tmp/redis-cluster/snapshots/$SNAP_TS/volumes.tsv"
export EBS_RESTORE_DIR="/tmp/redis-cluster/ebs-restore/$SNAP_TS"
mkdir -p "$EBS_RESTORE_DIR"
test -f "$SNAP_MAP"
test "$(wc -l < "$SNAP_MAP" | tr -d ' ')" -eq 12
test "$(cut -f3 "$SNAP_MAP" | sort -u | wc -l | tr -d ' ')" -eq 12
aws sts get-caller-identity
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get rediscluster redis-cluster

: > "$EBS_RESTORE_DIR/replacement-volumes.tsv"
: > "$EBS_RESTORE_DIR/replacement-pv-pvc.yaml"
while IFS=$'\t' read -r POD KIND PVC OLD_PV OLD_VOL AZ SIZE_GIB SNAP; do
  case "$KIND" in
    data) test "$PVC" = "${POD%-*}-${POD}" ;;
    nodeconf) test "$PVC" = "node-conf-$POD" ;;
    *) echo "Loại PVC không hợp lệ: $KIND" >&2; exit 1 ;;
  esac
  read -r SNAP_SOURCE SNAP_SIZE SNAP_STATE < <(aws ec2 describe-snapshots \
    --region "$AWS_REGION" --snapshot-ids "$SNAP" \
    --query 'Snapshots[0].[VolumeId,VolumeSize,State]' --output text)
  test "$SNAP_SOURCE" = "$OLD_VOL"
  test "$SNAP_SIZE" = "$SIZE_GIB"
  test "$SNAP_STATE" = completed
  NEW_VOL="$(aws ec2 create-volume --region "$AWS_REGION" --snapshot-id "$SNAP" \
    --availability-zone "$AZ" --volume-type gp3 --query VolumeId --output text)"
  aws ec2 wait volume-available --region "$AWS_REGION" --volume-ids "$NEW_VOL"
  NEW_PV="restore-${POD}-${KIND}-${SNAP#snap-}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$PVC" "$OLD_PV" "$OLD_VOL" "$NEW_PV" "$NEW_VOL" \
    >> "$EBS_RESTORE_DIR/replacement-volumes.tsv"
  cat >> "$EBS_RESTORE_DIR/replacement-pv-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $NEW_PV
spec:
  capacity:
    storage: ${SIZE_GIB}Gi
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: redis-cluster-gp3
  claimRef:
    namespace: $NAMESPACE
    name: $PVC
  csi:
    driver: ebs.csi.aws.com
    volumeHandle: $NEW_VOL
    fsType: ext4
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: [$AZ]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NAMESPACE
spec:
  volumeName: $NEW_PV
  storageClassName: redis-cluster-gp3
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${SIZE_GIB}Gi
---
EOF
done < "$SNAP_MAP"
test "$(wc -l < "$EBS_RESTORE_DIR/replacement-volumes.tsv" | tr -d ' ')" -eq 12
echo "Kiểm tra $EBS_RESTORE_DIR/replacement-pv-pvc.yaml và replacement-volumes.tsv trước khi tiếp tục"
```

### 2. Dừng cluster và thay PVC

Dừng ứng dụng ghi và CronJob backup, rồi xác nhận không còn Job backup đang chạy. Đặt operator về 0 trước khi scale hai StatefulSet để operator không tạo lại Pod. **Nếu bước thay PVC lỗi, giữ operator và StatefulSet ở 0; kiểm tra lại bản đồ volume trước khi tiếp tục.** Không khởi động với chỉ một phần PVC được khôi phục.

```bash
for STS in redis-cluster-leader redis-cluster-follower; do
  test "$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get sts "$STS" \
    -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy.whenScaled}')" = Retain
done
kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system scale deploy/redis-cluster-operator --replicas=0
kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system wait --for=delete pod -l name=redis-cluster-operator --timeout=3m
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-cluster-leader sts/redis-cluster-follower --replicas=0
for POD in redis-cluster-leader-{0..2} redis-cluster-follower-{0..2}; do
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=delete "pod/$POD" --timeout=5m
done

# PV cũ có Retain: xóa PVC không xóa EBS volume cũ.
while IFS=$'\t' read -r PVC OLD_PV OLD_VOL NEW_PV NEW_VOL; do
  test "$(kubectl --context "$KUBE_CONTEXT" get pv "$OLD_PV" \
    -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')" = Retain
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" delete pvc "$PVC" --wait=true
done < "$EBS_RESTORE_DIR/replacement-volumes.tsv"
kubectl --context "$KUBE_CONTEXT" apply -f "$EBS_RESTORE_DIR/replacement-pv-pvc.yaml"
while IFS=$'\t' read -r PVC OLD_PV OLD_VOL NEW_PV NEW_VOL; do
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait \
    --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC" --timeout=5m
  test "$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc "$PVC" \
    -o jsonpath='{.status.phase}')" = Bound
  test "$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc "$PVC" \
    -o jsonpath='{.spec.volumeName}')" = "$NEW_PV"
done < "$EBS_RESTORE_DIR/replacement-volumes.tsv"
```

### 3. Chạy lại và xác minh

Chỉ khởi động khi cả 12 PVC đã `Bound` đúng PV mới. Cấu hình hiện tại dùng 3 leader, 3 follower và 2 operator replica; nếu bạn đã thay số này trong CR/Helm, dùng đúng giá trị đã ghi lại trước khi dừng.

```bash
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-cluster-leader sts/redis-cluster-follower --replicas=3
kubectl --context "$KUBE_CONTEXT" -n redis-cluster-system scale deploy/redis-cluster-operator --replicas=2
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=condition=Ready pod -l role=leader --timeout=15m
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=condition=Ready pod -l role=follower --timeout=15m
KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc -o wide
```

Kiểm tra thêm `CLUSTER NODES`, số key theo từng master, replica đồng bộ, ứng dụng đọc được dữ liệu và TTL của key mẫu trước khi mở lại traffic ghi. Snapshot là trạng thái quá khứ nên key hết hạn theo thời gian thực có thể không còn sau khi khởi động. Nếu cluster không khỏe, **đừng xóa volume cũ hay các snapshot**; dừng workload và điều tra `nodes.conf`, log Redis/operator và mapping 12 volume. Các PV cũ ở trạng thái `Released` cùng EBS volume cũ được giữ để có thể rebind thủ công; không chạy `CLUSTER RESET` hay xoá PVC thêm khi chưa xác định nguyên nhân. Sau khi thử restore thành công, mới lập chính sách giữ/xóa snapshot và volume cũ để tránh chi phí kéo dài.

### 4. Dọn snapshot và volume cũ sau khi đã xác minh

Chỉ dọn sau khi đã kiểm tra dữ liệu ứng dụng, cluster và replica, và đã quyết định không cần dùng bộ snapshot/volume cũ để rollback. Script [`cleanup-ebs-restore.sh`](cleanup-ebs-restore.sh) yêu cầu cả `volumes.tsv` và `replacement-volumes.tsv`, chỉ định AWS account/Region/Kubernetes context và đối chiếu account đang dùng; nó kiểm tra 12 PVC mới, PV cũ ở trạng thái `Released` với `Retain`, volume cũ ở trạng thái `available`, và tag của snapshot. Mặc định script **chỉ xem trước**. Cần quyền đọc AWS/Kubernetes và, khi thực thi, `ec2:DeleteVolume`, `ec2:DeleteSnapshot` cùng quyền xóa PV.

```bash
export SNAP_TS=<SNAP_TS>   # cùng giá trị với bước snapshot và bước restore EBS
export EBS_RESTORE_DIR="/tmp/redis-cluster/ebs-restore/$SNAP_TS"   # chứa replacement-volumes.tsv
SNAP_MAP="/tmp/redis-cluster/snapshots/$SNAP_TS/volumes.tsv"       # bản đồ snapshot nằm ở thư mục snapshot
REPLACEMENT_MAP="$EBS_RESTORE_DIR/replacement-volumes.tsv"
EXPECTED_AWS_ACCOUNT_ID="<AWS_ACCOUNT_ID>"  # thay bằng account ID 12 chữ số của cluster
KUBE_CONTEXT="$(kubectl config current-context)"
AWS_REGION=ap-southeast-1

CLEANUP_ARGS=(
  --snapshot-map "$SNAP_MAP"
  --replacement-map "$REPLACEMENT_MAP"
  --context "$KUBE_CONTEXT"
  --region "$AWS_REGION"
  --account-id "$EXPECTED_AWS_ACCOUNT_ID"
  --old-volumes --snapshots
)
bash redis-cluster/cleanup-ebs-restore.sh "${CLEANUP_ARGS[@]}"            # xem trước
bash redis-cluster/cleanup-ebs-restore.sh "${CLEANUP_ARGS[@]}" --execute  # xóa đúng danh sách đã kiểm tra
```

Có thể chỉ chọn `--old-volumes` để giữ snapshot thêm một thời gian, rồi chạy lại với `--snapshots` khi hết thời gian giữ backup. Script xóa **volume cũ** trong `replacement-volumes.tsv`, không xóa 12 volume mới đang được PVC dùng; nếu chọn cả hai, snapshot được xóa sau cùng. Giữ hai file bản đồ và log chạy script cho đến khi đã xác nhận cleanup hoàn tất. [AWS yêu cầu volume ở trạng thái `available` trước khi xóa](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-deleting-volume.html); với PV có `Retain`, [Kubernetes để việc dọn tài nguyên lưu trữ cho quản trị viên](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#retain).

## Lưu ý vận hành

- Replication bất đồng bộ, nên write gần lúc failover có thể mất.
- Backup không có ảnh chụp chung cho cả cluster. Key liên quan đến nhau nằm trên các shard khác nhau có thể lệch nhau vài giây trong bản backup. Dùng hash tag khi cần các key cùng slot.
- Đổi số master cần resharding bằng `redis-cli --cluster reshard`, không chỉ đổi `replicas`. Thao tác này không được mô tả trong thư mục này.
- `keepAfterDelete: true` giữ PVC khi xóa CR. Dọn PVC và volume EBS cần làm thủ công.
- cert-manager gia hạn `redis-cluster-tls` mỗi 90 ngày. Sau khi gia hạn, restart tuần tự các Pod để nạp chứng chỉ mới. CA `redis-cluster-ca` cần backup và có kế hoạch xoay vòng riêng.
- Image node được ghim theo base `quay.io/opstree/redis:v7.0.15` và tag `thoaiky1992/redis-cluster:7.0.15-fqdn.1`. Nâng cấp base hoặc đổi tag là thay đổi có chủ đích: build lại image, kiểm tra `CLUSTER NODES` có FQDN, rồi mới sửa `redis-cluster.yaml`.

## Trạng thái kiểm chứng

- **Backup, đã chạy trên EKS** (cluster `dev-demo`, namespace `redis-cluster`): job thủ công thành công, upload đủ `cluster-nodes.txt`, `metadata.json`, `SHA256SUMS`, `shard-01..03/dump.rdb` và `_SUCCESS`.
- **Image restore, đã kiểm chứng cục bộ** với Redis `7.0.15` trong Docker: image mới xuất 2 lệnh `RESTORE` qua network namespace của Redis nguồn; pipe vào Redis đích trả `errors: 0`, giá trị khớp và TTL được giữ nguyên.
- **Restore trên EKS, đã hoàn tất theo mục Restore ở trên** (backup `20261029T150024Z`, shard-02 có 2 key). Sau khi ghi: master `leader-1` có `DBSIZE=2`, replica `follower-1` đồng bộ `DBSIZE=2` với `master_link_status:up`, cluster `ok` với 16384 slot. Backup sau restore ghi nhận `keys=2`.
- **Thử restore dữ liệu lớn trên EKS ngày 30/10/2026:** tạo RDB Redis 7.0.15 cục bộ chứa 32.770 key (32.768 giá trị 4 KiB, một giá trị 8 MiB, một marker; 3.277 key có TTL). `redis-check-rdb` đọc đủ 32.770 key; RDB 138 MiB, RESP 139 MiB; chuyển đổi mất 8 giây. Gửi RESP qua `kubectl exec` tới master đang giữ slot mất 59 giây, `errors: 0, replies: 32770`. Master và replica đều có `DBSIZE=32770`; SHA-256 của giá trị 8 MiB khớp, TTL còn hiệu lực, AOF báo `aof_last_write_status:ok`, cluster `ok`. Đã xóa toàn bộ key thử bằng `UNLINK`; cả 6 node trở về `DBSIZE=0`. Bài thử này không đi qua S3 vì lúc kiểm tra namespace không có CronJob backup; kết quả S3 của bản backup nhỏ được ghi ở trên.
- **EBS snapshot/restore:** quy trình trong tài liệu này mới được đối chiếu với tên 12 PVC, chính sách `Retain`, AZ và cấu hình EBS CSI đang chạy; chưa thực hiện restore EBS thực tế trên staging hoặc production.
- **Dọn EBS:** đã thử chế độ xem trước và `--execute` của `cleanup-ebs-restore.sh` bằng AWS/Kubernetes giả lập; chưa xóa snapshot, PV hay volume thật.

Trước khi dùng cho production, chạy lại đầy đủ quy trình restore trên staging và kiểm tra: tên Service và Pod, label `role`, hostname mà operator khai báo, và phân bố AZ thực tế.

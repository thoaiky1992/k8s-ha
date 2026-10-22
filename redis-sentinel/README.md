# Redis Sentinel HA trên EKS

Thư mục này dùng [OT Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator) **0.27.0** để quản lý `RedisReplication` 3 node và `RedisSentinel` 3 node. Sentinel bầu primary mới khi primary gặp sự cố. Redis, replication và Sentinel đều dùng TLS. Đây là replication HA, không có sharding; mỗi Redis Pod có một PVC EBS gp3 riêng.

## Các file

| File | Vai trò |
| --- | --- |
| `namespace.yaml` | Tạo `redis-sentinel` và `redis-sentinel-system`. |
| `pv.yaml` | StorageClass `redis-sentinel-gp3`; EBS CSI cấp PV động. |
| `pvc.yaml` | PVC và Pod thử storage tùy chọn. |
| `secret.yaml.example` | Mẫu Secret `redis-sentinel-auth` chứa khóa `redis-password`. |
| `certificate.yaml` | cert-manager tạo CA nội bộ và Secret `redis-sentinel-tls`. |
| `operator-values.yaml` | Chạy hai replica operator và chỉ theo dõi namespace `redis-sentinel`. |
| `redis-replication-configmap.yaml` | Bật AOF, giới hạn bộ nhớ, chính sách eviction và TLS replication. |
| `redis-sentinel-replication.yaml` | `RedisReplication`: 3 Redis Pod, PVC và phân bố AZ. |
| `redis-sentinel-configmap.yaml` | Bật TLS giữa Sentinel với Redis và giữa các Sentinel. |
| `redis-sentinel.yaml` | `RedisSentinel`: 3 Sentinel Pod và phân bố AZ. |
| `backup/Dockerfile` | Image backup gồm Redis tools và AWS CLI. |
| `backup-configmap.yaml` | Script tạo RDB, kiểm tra checksum và upload lên S3. |
| `backup-cronjob.yaml` | ServiceAccount và CronJob backup lúc 01:00 hằng ngày. |
| `check.sh` | Kiểm tra context, số node/AZ và EBS CSI. |
| `check-master.sh` | Kiểm tra Sentinel đã đăng ký master, quorum và số replica của master. |
| `clean-released-pv.sh` | Liệt kê và xóa các PV ở trạng thái `Released` (chỉ xóa PV object, không xóa volume EBS). |

## Điều kiện

- Có `kubectl`, `jq`, Helm 3 và quyền cài CRD toàn cluster. Máy thực hiện restore cần AWS CLI và Docker. Docker dùng để chạy `redis-check-rdb` từ image backup. `sha256sum` có trên Linux; macOS dùng `shasum -a 256`.
- Có ít nhất **3 node Ready trên 3 AZ**. Mỗi Redis Pod request 1 GiB RAM, limit 2 GiB; mỗi Sentinel request 64 MiB.
- Dùng EKS managed EC2 node group và có [Amazon EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html). Terraform của repo khai báo driver tại [`09.ebs-csi-driver.tf`](../terraform/01.kubernetes/09.ebs-csi-driver.tf). EKS Auto Mode cần StorageClass khác.
- Máy cài đặt truy cập được `ghcr.io`; node kéo được image từ `quay.io/opstree`.
- Terraform tầng `01.kubernetes` đã cài cert-manager. Kiểm tra operator/CRD hiện có trước khi cài để tránh hai release cùng quản lý CRD. Helm không tự cập nhật CRD khi `helm upgrade`; xem [ghi chú release 0.27.0](https://github.com/OT-CONTAINER-KIT/redis-operator/releases/tag/v0.27.0).

## Tên dịch vụ và TLS

Workload chạy trong namespace `redis-sentinel`; operator chạy trong `redis-sentinel-system`. `RedisReplication` có tên `redis-sentinel`. `RedisSentinel` cũng có tên `redis-sentinel`, vì vậy operator tạo StatefulSet/Service Sentinel với hậu tố `-sentinel`, ví dụ `redis-sentinel-sentinel`.

`certificate.yaml` tạo CA `redis-sentinel-ca` và chứng chỉ máy chủ `redis-sentinel-tls`. DNS SAN bao phủ Service và headless Service của cả Redis replication lẫn Sentinel. Nếu cluster dùng DNS suffix khác `cluster.local`, sửa `dnsNames` trước khi áp dụng. Client phải tin cậy `tls.crt` trong Secret `redis-sentinel-ca`; không tắt xác minh chứng chỉ.

Với image Redis/Sentinel `v7.0.15`, biến `REDIS_TLS_CA_KEY` tương thích với tên biến CA mà entrypoint vẫn dùng. `tls-auth-clients no` cho phép xác thực client bằng mật khẩu, nhưng kết nối vẫn được mã hóa và client vẫn phải xác minh CA. Sentinel dùng `resolveHostnames` và `announceHostnames` để trả FQDN khớp SAN cho client.

> **Lưu ý khi đổi từ bộ manifest cũ:** Kubernetes không đổi tên namespace hay resource tại chỗ. Áp dụng bộ manifest mới sẽ tạo một cụm mới trong namespace `redis-sentinel`, không di chuyển dữ liệu từ namespace `redis`. Nếu cụm cũ đã chứa dữ liệu, hãy backup từ cụm cũ, restore có kiểm soát sang cụm mới, chuyển endpoint client rồi mới dọn resource cũ.

## Cài đặt

Chạy từ root repository. Tạo mật khẩu mạnh trong `secret.yaml`; file này bị bỏ qua bởi `.gitignore`. Không áp dụng file mẫu và không commit Secret.

```bash
set -euo pipefail
aws eks update-kubeconfig --region <region> --name <cluster-name>
kubectl config get-contexts
export KUBE_CONTEXT="$(kubectl config current-context)"

cp redis-sentinel/secret.yaml.example redis-sentinel/secret.yaml
chmod 600 redis-sentinel/secret.yaml
${EDITOR:-vi} redis-sentinel/secret.yaml

kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/pv.yaml

kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/certificates.cert-manager.io crd/issuers.cert-manager.io --timeout=120s

kubectl --context "$KUBE_CONTEXT" -n cert-manager wait --for=condition=Available \
  deployment/cert-manager deployment/cert-manager-webhook --timeout=5m

kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/certificate.yaml

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel wait --for=condition=Ready \
  issuer/redis-sentinel-selfsigned certificate/redis-sentinel-ca \
  issuer/redis-sentinel-ca certificate/redis-sentinel-tls --timeout=5m

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get secret redis-sentinel-tls

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get secret redis-sentinel-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/redis-sentinel-ca.crt
test -s /tmp/redis-sentinel-ca.crt

helm --kube-context "$KUBE_CONTEXT" upgrade --install redis-sentinel-operator \
  oci://ghcr.io/ot-container-kit/charts/redis-operator \
  --version 0.27.0 --namespace redis-sentinel-system \
  -f redis-sentinel/operator-values.yaml --wait --timeout 10m

kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/redisreplications.redis.redis.opstreelabs.in --timeout=120s

kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/redissentinels.redis.redis.opstreelabs.in --timeout=120s

kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-replication-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-sentinel-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-sentinel-replication.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-sentinel.yaml
```

## Kiểm tra

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get redisreplication redis-sentinel
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get redissentinel redis-sentinel
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get pods,pvc,svc -o wide
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel-system get pods

bash redis-sentinel/check-master.sh
```

Redis phải trả `PONG`; Sentinel phải trả hostname của primary. Nếu chưa Ready, xem `kubectl describe redisreplication redis-sentinel -n redis-sentinel`, `kubectl describe redissentinel redis-sentinel -n redis-sentinel` và log operator. Không giả định Pod ordinal 0 luôn là primary sau failover.

## Backup tự động lên AWS S3

AOF trên PVC và ba bản sao Redis không thay thế backup. CronJob tạo RDB nhất quán từ primary do Sentinel công bố, kiểm tra RDB, tạo SHA-256 rồi upload lên S3. Mỗi lần chạy có cấu trúc:

```text
s3://<bucket>/redis-sentinel/<UTC-timestamp>/
├── dump.rdb
├── metadata.json
├── SHA256SUMS
└── _SUCCESS
```

`_SUCCESS` chỉ được upload cuối cùng; không restore một thư mục thiếu file này.

### 1. Tạo S3 bucket và quyền bằng Terraform

Đặt tên bucket duy nhất toàn cục trong `terraform/01.kubernetes/terraform.tfvars`:

```hcl
redis_sentinel_backup_bucket_name    = "prod-demo-redis-sentinel-backups-123456789012"
redis_sentinel_backup_retention_days = 30
```

Sau đó chạy Terraform tầng Kubernetes. File `14.redis-sentinel-backup.tf` tạo bucket private, bật versioning, mã hóa SSE-S3, lifecycle retention, IAM role quyền tối thiểu trên prefix `redis-sentinel/` và EKS Pod Identity association cho ServiceAccount `redis-sentinel-backup`.

```bash
terraform -chdir=terraform/01.kubernetes plan -var-file=terraform.tfvars
terraform -chdir=terraform/01.kubernetes apply -var-file=terraform.tfvars

export S3_BUCKET="$(terraform -chdir=terraform/01.kubernetes output -json values | \
  jq -r '.redis_sentinel_backup.bucket_name')"
test -n "$S3_BUCKET" && test "$S3_BUCKET" != null
```

CronJob dùng EKS Pod Identity; không tạo `AWS_ACCESS_KEY_ID` hoặc `AWS_SECRET_ACCESS_KEY` trong Kubernetes Secret.

### 2. Build image backup

Đặt `BACKUP_IMAGE` tới registry của bạn. Lệnh dưới tạo image đa kiến trúc có `redis-cli`, `redis-check-rdb` và AWS CLI:

```bash
export BACKUP_IMAGE="thoaiky1992/redis-sentinel-backup:1.0.0"

docker buildx build --platform linux/amd64,linux/arm64 \
  -f redis-sentinel/backup/Dockerfile \
  -t "$BACKUP_IMAGE" --push redis-sentinel/backup
```

Sửa các giá trị sau trước khi áp dụng:

- `S3_BUCKET` trong `backup-configmap.yaml` thành output Terraform ở trên. Giữ `S3_PREFIX=redis-sentinel` trừ khi cập nhật IAM policy tương ứng.
- `image` và `AWS_REGION` trong `backup-cronjob.yaml` theo registry/region thực tế.
- `command: ["/bin/bash", "/backup-script/backup.sh"]` trong `backup-cronjob.yaml` là bắt buộc với image `1.0.0`. ENTRYPOINT của image là `/bin/sh` (dash), không hỗ trợ `pipefail` mà script cần. Dockerfile đã đổi ENTRYPOINT sang bash; build lại image để hai bên đồng bộ.
- `emptyDir.sizeLimit` và `ephemeral-storage` phải lớn hơn kích thước RDB lớn nhất dự kiến.

### 3. Cài CronJob lúc 01:00 hằng ngày

```bash
kubectl config get-contexts
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/backup-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/backup-cronjob.yaml
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get cronjob redis-sentinel-backup
```

CronJob dùng `schedule: "0 1 * * *"` và `timeZone: Asia/Ho_Chi_Minh`, vì vậy chạy hằng ngày lúc **01:00 giờ Việt Nam**. `concurrencyPolicy: Forbid` ngăn hai backup chạy chồng nhau.

Chạy thử ngay, xem log và xác nhận object trên S3:

```bash
JOB="redis-sentinel-backup-manual-$(date +%s)"

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel create job \
  --from=cronjob/redis-sentinel-backup "$JOB"

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel wait \
  --for=condition=Complete "job/$JOB" --timeout=2h

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel logs "job/$JOB"

aws s3 ls "s3://$S3_BUCKET/redis-sentinel/" --recursive
```

CronJob cố ý không upload mật khẩu Redis hay khóa riêng CA. Lưu `redis-sentinel-auth` và `redis-sentinel-ca` trong AWS Secrets Manager hoặc kho bí mật đã mã hóa riêng để disaster recovery. Theo dõi Job thất bại và diễn tập restore định kỳ; một object tồn tại trên S3 chưa đủ nếu checksum/RDB chưa từng được kiểm tra.

## Restore

Restore ghi đè dữ liệu Redis, nên luôn thử ở staging trước. Production cần maintenance window và dừng toàn bộ client ghi trước khi bắt đầu. Restore chỉ được coi là thành công khi bước 8 (restart từng Pod rồi đếm key) đạt.

> **Cảnh báo về PVC:** trên cụm này, xóa `RedisReplication` làm operator xóa luôn các PVC, dù `persistentVolumeClaimRetentionPolicy` là `Retain`. Dữ liệu EBS vẫn còn vì StorageClass `redis-sentinel-gp3` có `reclaimPolicy: Retain`: PV chuyển sang `Released` thay vì bị xóa. PVC cũ không tự gắn lại được. Vì vậy phải snapshot EBS ở bước 2 trước khi xóa CR. Không xóa CR khi chưa có snapshot.

Quy trình dưới đây là restore vào PVC mới, rồi nạp RDB vào `redis-sentinel-0` và để hai replica đồng bộ. Các bước 1–7 đã chạy thử trên cụm dev. Bước 8 là điều kiện để kết luận thành công, vì dữ liệu chỉ nằm trong bộ nhớ có thể mất sau restart.

### 1. Tải backup từ S3 và xác minh

```bash
set -euo pipefail
export KUBE_CONTEXT="$(kubectl config current-context)"
export NAMESPACE=redis-sentinel
export S3_BUCKET="$(terraform -chdir=terraform/01.kubernetes output -json values | \
  jq -r '.redis_sentinel_backup.bucket_name')"
export BACKUP_TIMESTAMP="20261028T073528Z"

# Biến không được giữ giữa các terminal. Dừng ngay nếu thiếu, vì aws s3 sync
# với đường dẫn rỗng không báo lỗi và không tải file nào.
: "${S3_BUCKET:?S3_BUCKET chưa đặt}"
: "${BACKUP_TIMESTAMP:?BACKUP_TIMESTAMP chưa đặt}"
aws s3 ls "s3://$S3_BUCKET/redis-sentinel/$BACKUP_TIMESTAMP/"   # phải thấy 4 file

BACKUP_DIR="$(mktemp -d)"

aws s3 sync "s3://$S3_BUCKET/redis-sentinel/$BACKUP_TIMESTAMP/" "$BACKUP_DIR/"
test -s "$BACKUP_DIR/_SUCCESS"
test -s "$BACKUP_DIR/SHA256SUMS"
test -s "$BACKUP_DIR/dump.rdb"

# Linux: sha256sum -c SHA256SUMS. macOS: shasum -a 256 -c SHA256SUMS.
(cd "$BACKUP_DIR" && shasum -a 256 -c SHA256SUMS)

# redis-check-rdb chạy từ image backup, không cần cài Redis tools trên máy.
RDB_CHECK="$(docker run --rm -v "$BACKUP_DIR:/data:ro" --entrypoint redis-check-rdb \
  thoaiky1992/redis-sentinel-backup:1.0.0 /data/dump.rdb)"
grep -q "RDB looks OK" <<<"$RDB_CHECK"

# Số key trong backup, lấy từ dòng "[info] N keys read". Dùng cho bước 5 và bước 8.
export EXPECTED_KEYS="$(awk '/keys read/{print $2}' <<<"$RDB_CHECK")"
echo "EXPECTED_KEYS=$EXPECTED_KEYS"
```

`EXPECTED_KEYS` được đặt tự động bởi khối trên trong cùng terminal. Nếu mở terminal mới, chạy lại khối này trước khi làm bước 5 và bước 8.

### 2. Snapshot EBS của PVC hiện tại

Bỏ qua bước này nếu cụm chưa có dữ liệu cần giữ. Ngược lại, snapshot trước khi xóa CR:

```bash
SNAPSHOT_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for ORDINAL in 0 1 2; do
  PVC="redis-sentinel-redis-sentinel-$ORDINAL"
  
  # Lấy PV và Volume ID tự động
  PV="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')"
  VOL="$(kubectl --context "$KUBE_CONTEXT" get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')"
  
  # Đặt tên snapshot (Snapshot Name)
  SNAPSHOT_NAME="redis-sentinel-pre-restore-$SNAPSHOT_TIMESTAMP-$ORDINAL"
  
  # Tạo snapshot, gán Tag Name và lấy SnapshotId
  SNAPSHOT_ID="$(aws ec2 create-snapshot --region ap-southeast-1 --volume-id "$VOL" \
    --description "redis-sentinel pre-restore ordinal $SNAPSHOT_TIMESTAMP $ORDINAL" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$SNAPSHOT_NAME}]" \
    --query SnapshotId --output text)"
    
  echo "[Ordinal $ORDINAL] Snapshot Name: $SNAPSHOT_NAME | ID: $SNAPSHOT_ID"
done
```

Chờ các snapshot ở trạng thái `completed` (`aws ec2 describe-snapshots`) trước khi tiếp tục.

### 3. Dừng Sentinel và Redis

```bash
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" delete redissentinel redis-sentinel --wait=true
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" delete redisreplication redis-sentinel --wait=true

# PV phải ở trạng thái Released (không bị xóa). PVC đã bị operator xóa.
kubectl --context "$KUBE_CONTEXT" get pv | grep redis-sentinel
```

### 4. Tạm tắt AOF và tạo lại cụm với PVC mới (rỗng)

Tạm tắt AOF để Redis nạp được RDB khi khởi động. Các thiết lập khác giữ nguyên:

```bash
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" patch \
  configmap redis-sentinel-redis-config --type merge \
  -p '{"data":{"redis-additional.conf":"appendonly no\nsave \"\"\nmaxmemory 1gb\nmaxmemory-policy noeviction\ntls-auth-clients no\ntls-replication yes\n"}}'

kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-sentinel-replication.yaml

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=condition=Ready \
  pod/redis-sentinel-0 pod/redis-sentinel-1 pod/redis-sentinel-2 --timeout=10m
```

Hàm tiện ích để gọi `redis-cli` trong Pod (Pod đã có `REDISCLI_AUTH` trong env, nên mật khẩu không xuất hiện trên máy):

```bash
rcli() {
  local ord="$1"; shift
  local h="redis-sentinel-${ord}.redis-sentinel-headless.${NAMESPACE}.svc.cluster.local"
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" exec "redis-sentinel-${ord}" -- \
    redis-cli --tls --cacert /tls/ca.crt --sni "$h" -h "$h" -p 6379 "$@"
}
```

### 5. Nạp RDB vào `redis-sentinel-0` và khởi động lại

```bash
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" cp \
  "$BACKUP_DIR/dump.rdb" redis-sentinel-0:/data/dump.rdb

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" delete pod redis-sentinel-0 --wait=true
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=condition=Ready \
  pod/redis-sentinel-0 --timeout=5m

rcli 0 DBSIZE   # phải khớp EXPECTED_KEYS. Đây chỉ là kiểm tra trong bộ nhớ, chưa đủ; xem bước 8.
```

### 6. Chờ replica đồng bộ rồi bật lại AOF

Sau khi restart, operator có thể tạm thời báo nhiều master trong vài phút trong lúc hội tụ. Đừng can thiệp thủ công khi topology đang chuyển động. Chờ đến khi:

```bash
rcli 0 INFO replication | grep connected_slaves   # connected_slaves:2
rcli 1 INFO replication | grep -E "^role|master_link_status"   # role:slave, master_link_status:up
rcli 2 INFO replication | grep -E "^role|master_link_status"   # role:slave, master_link_status:up
```

Nếu sau 5 phút vẫn không hội tụ, xem log operator: `kubectl -n redis-sentinel-system logs deploy/redis-operator`.

Khi replica đã đồng bộ, bật AOF trên cả ba Pod và chờ rewrite hoàn tất:

```bash
for ORD in 0 1 2; do rcli "$ORD" CONFIG SET appendonly yes; done

for ORD in 0 1 2; do
  until rcli "$ORD" INFO persistence | grep -q "aof_rewrite_in_progress:0"; do sleep 3; done
  rcli "$ORD" INFO persistence | grep aof_last_bgrewrite_status
done
```

### 7. Áp dụng lại cấu hình gốc của repo

```bash
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-replication-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-sentinel-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-sentinel-replication.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-sentinel.yaml

bash redis-sentinel/check-master.sh
```

Chạy bước 8 trước khi kết luận restore thành công. Sau đó xác nhận ứng dụng kết nối lại được rồi mới mở lại traffic ghi. Chạy backup mới ngay sau restore.

### 8. Kiểm tra độ bền sau restart (bắt buộc)

Kiểm tra trong bộ nhớ ở bước 5 là chưa đủ. Trên cụm đã thử, dữ liệu đúng khi đang chạy nhưng sau khi Pod restart chỉ còn những gì có trong AOF. Vì vậy phải restart từng Pod rồi đếm key. Restart replica trước, master sau cùng; restart master sẽ kích hoạt failover.

```bash
for ORD in 1 2 0; do
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" delete pod "redis-sentinel-${ORD}" --wait=true
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=condition=Ready "pod/redis-sentinel-${ORD}" --timeout=5m
  sleep 10   # để replica đồng bộ lại trước khi đếm
done

for ORD in 0 1 2; do
  echo "pod $ORD: DBSIZE=$(rcli "$ORD" DBSIZE) $(rcli "$ORD" INFO replication | tr -d '\r' | grep -E '^role') $(rcli "$ORD" CONFIG GET appendonly | tail -1)"
done
```

Mỗi Pod phải báo `DBSIZE=$EXPECTED_KEYS` và `appendonly yes`. Kiểm tra thêm danh sách key với `rcli 0 KEYS '*'` so với nội dung backup.

Nếu có Pod nào lệch `EXPECTED_KEYS`, **không kết luận restore thành công**. Dừng lại, giữ nguyên snapshot ở bước 2 và PV cũ, rồi kiểm tra `appendonlydir` của Pod đó trước khi làm bước khác.

### 9. Dọn PV cũ

Chỉ làm sau khi bước 8 đạt và snapshot ở bước 2 đã `completed`. Xóa volume EBS không hoàn tác được:

```bash
kubectl --context "$KUBE_CONTEXT" get pv | grep redis-sentinel   # các PV Released cũ
kubectl --context "$KUBE_CONTEXT" delete pv <pv-name>
aws ec2 delete-volume --region ap-southeast-1 --volume-id <vol-id>
```

Hoặc dùng script (có hỏi xác nhận trước khi xóa). Script chỉ xóa PV object, volume EBS vẫn còn và phải xóa riêng bằng `aws ec2 delete-volume` nếu không cần nữa:

```bash
bash ./redis-sentinel/clean-released-pv.sh
```

## Restore từ snapshot EBS (bước 2)

Phương án này khôi phục đúng trạng thái volume lúc chụp snapshot, gồm cả AOF và RDB. Không cần copy RDB thủ công và không cần tắt AOF. Đổi lại, dữ liệu hiện tại trên PVC bị thay thế hoàn toàn. Chỉ dùng khi đã có đủ snapshot `completed` của bước 2.

Lưu ý:
- Snapshot ở bước 2 được chụp khi Redis đang chạy, nên là crash-consistent. Mục 5 bên dưới (kiểm tra độ bền) là bắt buộc.
- Số key kỳ vọng là số key tại thời điểm chụp snapshot, không phải số key trong bản backup S3. Ghi lại `rcli 0 DBSIZE` ngay trước khi chụp snapshot ở bước 2 để làm mốc.
- Mỗi volume mới phải nằm đúng AZ của volume nguồn. Script bên dưới tự lấy AZ.
- PVC `redis-sentinel-redis-sentinel-N` phải bị xóa trước khi tạo lại cùng tên, vì PVC cũ đã Bound. Bước này thay thế dữ liệu hiện tại.

### 1. Tìm snapshot và AZ của từng ordinal

Dùng cùng giá trị `SNAPSHOT_TIMESTAMP` đã dùng khi chụp snapshot ở bước 2 (phần Snapshot). Tên tag `redis-sentinel-pre-restore-<TS>-<N>` chứa giá trị đó. Giá trị dưới đây là ví dụ, thay bằng timestamp của lần chụp:

```shell
SNAPSHOT_TIMESTAMP="20261028T103114Z"

for ORDINAL in 0 1 2; do
  SNAPSHOT_NAME="redis-sentinel-pre-restore-$SNAPSHOT_TIMESTAMP-$ORDINAL"
  
  # Tìm Snapshot ID dựa vào Tag Name
  SNAP="$(aws ec2 describe-snapshots --region ap-southeast-1 --owner-ids self \
    --filters "Name=tag:Name,Values=$SNAPSHOT_NAME" \
              "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId' --output text)"
    
  # Kiểm tra xem có tìm thấy snapshot hợp lệ không trước khi gọi tiếp các lệnh sau
  if [ -z "$SNAP" ] || [ "$SNAP" = "None" ]; then
    echo "[-] Không tìm thấy snapshot với tên: $SNAPSHOT_NAME cho ordinal $ORDINAL"
    continue
  fi

  VOL="$(aws ec2 describe-snapshots --region ap-southeast-1 --snapshot-ids "$SNAP" \
    --query 'Snapshots[0].VolumeId' --output text)"
    
  AZ="$(aws ec2 describe-volumes --region ap-southeast-1 --volume-ids "$VOL" \
    --query 'Volumes[0].AvailabilityZone' --output text)"
    
  echo "[+] ordinal $ORDINAL: snapshot=$SNAP volume=$VOL az=$AZ"
done
```

Nếu có ordinal nào không ra snapshot, dừng lại. Không tiếp tục khi thiếu snapshot.

### 2. Tạm dừng operator, Sentinel và Redis

Ghi lại số replicas của operator để bật lại đúng ở bước 4:

```bash
ORIGINAL_OPERATOR_REPLICAS="$(kubectl --context "$KUBE_CONTEXT" -n redis-sentinel-system \
  get deploy redis-operator -o jsonpath='{.spec.replicas}')"

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel-system scale deploy/redis-operator --replicas=0
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-sentinel-sentinel --replicas=0
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-sentinel --replicas=0
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=delete pod \
  -l 'role in (replication,sentinel)' --timeout=5m
```

Operator phải ở 0 cho đến hết bước 3. Nếu operator chạy lại khi PVC đang được thay, nó có thể tạo PVC mới rỗng cho một ordinal và cụm sẽ không có dữ liệu như mong đợi.

### 3. Thay PVC bằng volume từ snapshot

Với mỗi ordinal, xóa PVC cũ, tạo volume từ snapshot trong đúng AZ, rồi tạo PV và PVC tĩnh với đúng tên mà StatefulSet cần:

```bash
# Thay bằng timestamp đã dùng khi chụp snapshot.
SNAPSHOT_TIMESTAMP="20261028T103114Z"

# Tên PV phải duy nhất cho mỗi lần restore (chữ thường để hợp lệ với Kubernetes).
RUN_ID="$(echo "$SNAPSHOT_TIMESTAMP" | tr 'TZ' 'tz')"

# Chạy trong subshell để `exit` không đóng terminal của bạn.
(
set -euo pipefail

# Kiểm tra đủ snapshot và tên PV chưa tồn tại cho cả 3 ordinal trước khi xóa PVC nào.
for ORDINAL in 0 1 2; do
  SNAPSHOT_NAME="redis-sentinel-pre-restore-$SNAPSHOT_TIMESTAMP-$ORDINAL"
  SNAP="$(aws ec2 describe-snapshots --region ap-southeast-1 --owner-ids self \
    --filters "Name=tag:Name,Values=$SNAPSHOT_NAME" "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId' --output text)"
  if [ -z "$SNAP" ] || [ "$SNAP" = "None" ]; then
    echo "[-] Thiếu snapshot $SNAPSHOT_NAME. Dừng trước khi xóa PVC."
    exit 1
  fi
  if kubectl --context "$KUBE_CONTEXT" get pv "redis-sentinel-restore-${RUN_ID}-${ORDINAL}" >/dev/null 2>&1; then
    echo "[-] PV redis-sentinel-restore-${RUN_ID}-${ORDINAL} đã tồn tại. Dừng; xem mục Sự cố bên dưới."
    exit 1
  fi
done

for ORDINAL in 0 1 2; do
  SNAPSHOT_NAME="redis-sentinel-pre-restore-$SNAPSHOT_TIMESTAMP-$ORDINAL"

  # Query theo Tag Name thay vì description
  SNAP="$(aws ec2 describe-snapshots --region ap-southeast-1 --owner-ids self \
    --filters "Name=tag:Name,Values=$SNAPSHOT_NAME" \
              "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId' --output text)"

  # Kiểm tra xem có tìm thấy snapshot hợp lệ hay không
  if [ -z "$SNAP" ] || [ "$SNAP" = "None" ]; then
    echo "[-] Không tìm thấy snapshot với Tag Name: $SNAPSHOT_NAME cho ordinal $ORDINAL"
    exit 1
  fi

  VOL="$(aws ec2 describe-snapshots --region ap-southeast-1 --snapshot-ids "$SNAP" \
    --query 'Snapshots[0].VolumeId' --output text)"
    
  AZ="$(aws ec2 describe-volumes --region ap-southeast-1 --volume-ids "$VOL" \
    --query 'Volumes[0].AvailabilityZone' --output text)"

  # Xóa PVC cũ (PV cũ chuyển sang Released, không bị xóa).
  kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" delete pvc \
    "redis-sentinel-redis-sentinel-${ORDINAL}" --wait=true

  NEW_VOL="$(aws ec2 create-volume --region ap-southeast-1 --availability-zone "$AZ" \
    --snapshot-id "$SNAP" --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=redis-sentinel-restore-${RUN_ID}-${ORDINAL}}]" \
    --query VolumeId --output text)"
  aws ec2 wait volume-available --region ap-southeast-1 --volume-ids "$NEW_VOL"

  kubectl --context "$KUBE_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: redis-sentinel-restore-${RUN_ID}-${ORDINAL}
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: redis-sentinel-gp3
  csi:
    driver: ebs.csi.aws.com
    volumeHandle: ${NEW_VOL}
    fsType: ext4
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values:
                - ${AZ}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-sentinel-redis-sentinel-${ORDINAL}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: redis-sentinel-gp3
  volumeName: redis-sentinel-restore-${RUN_ID}-${ORDINAL}
  resources:
    requests:
      storage: 20Gi
EOF
done

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc
)
```

Tất cả PVC `redis-sentinel-redis-sentinel-0/1/2` phải ở trạng thái `Bound` trước khi sang bước 4.

### 4. Áp dụng lại cấu hình và bật lại cụm

```bash
kubectl --context "$KUBE_CONTEXT" apply -f redis-sentinel/redis-replication-configmap.yaml   # appendonly yes

kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-sentinel --replicas=3
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" scale sts/redis-sentinel-sentinel --replicas=3
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" rollout status sts/redis-sentinel --timeout=10m

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel-system scale deploy/redis-operator \
  --replicas="${ORIGINAL_OPERATOR_REPLICAS:-2}"   # mặc định 2 theo operator-values.yaml
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel-system rollout status deploy/redis-operator --timeout=3m
```

**Đây là bước dễ bị bỏ sót.** Nếu operator vẫn ở 0 replicas, không ai cấu hình lại replication và Sentinel. Khi đó `check-master.sh` báo `0.0.0.0:6379` và `NOQUORUM`. Nếu bước này lỗi vì biến trống, dùng giá trị mặc định ở trên.

Sau khi bật operator, topology có thể tạm lộn xộn 1–3 phút như ở bước 6 của phương án chính. Operator đang giữ leader lease và reconcile lại. Chờ hội tụ rồi mới kiểm tra.

### 5. Kiểm tra

Chạy lại bước 8 của phương án chính (restart từng Pod rồi đếm key), với số kỳ vọng là `rcli 0 DBSIZE` đã ghi trước khi chụp snapshot. Sau đó chạy:

```bash
bash redis-sentinel/check-master.sh
```

Không cần chạy bước 5 và bước 6 của phương án chính, vì AOF đã có sẵn trong snapshot.

Trước khi tin kết quả, kiểm tra PVC đã gắn đúng volume của đúng ordinal:

```bash
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc
kubectl --context "$KUBE_CONTEXT" get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,STATUS:.status.phase
```

Mỗi `redis-sentinel-redis-sentinel-N` phải gắn đúng `redis-sentinel-restore-<RUN_ID>-N`. Nếu không khớp, dừng lại và xem phần sự cố bên dưới.

Khi mọi thứ đạt, các PV cũ ở trạng thái `Released` có thể dọn bằng `bash ./redis-sentinel/clean-released-pv.sh`. Snapshot ở bước 2 vẫn được giữ lại cho đến khi bạn xóa thủ công.

### Sự cố: PV đã tồn tại hoặc PVC gắn nhầm PV

Triệu chứng: `kubectl apply` báo `spec.persistentvolumesource: Forbidden ... is immutable` khi tạo PV, hoặc PVC ở trạng thái `Pending`, hoặc PVC gắn vào một PV không đúng ordinal.

Nguyên nhân thường gặp:
- Tên PV `redis-sentinel-restore-<N>` cố định nên trùng với PV của lần restore trước. Đã sửa bằng `RUN_ID` trong tên PV ở trên; trước khi tạo, script kiểm tra tên chưa tồn tại.
- PV ở trạng thái `Available` (còn sót từ lần trước) có thể bị PVC mới bắt nhầm, vì PVC chọn PV còn trống phù hợp.
- Một lần chạy bị dừng giữa chừng: PVC đã xóa nhưng PV mới chưa tạo được.

Cách xử lý:

```bash
# Liệt kê PV còn sót và PVC đang gắn.
kubectl --context "$KUBE_CONTEXT" get pv -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pvc
```

- PVC `Pending` không có dữ liệu: xóa PVC đó, rồi để StatefulSet tạo lại.
- PV `Available` không dùng: kiểm tra snapshot còn tồn tại rồi mới xóa object PV và volume EBS.
- Không xóa PVC đang `Bound` vào Pod có dữ liệu trước khi xác nhận Pod đó đã được đồng bộ sang master.

### Sự cố: operator từ chối replicate từ master rỗng

Triệu chứng: `check-master.sh` báo `0.0.0.0:6379` và `NOQUORUM`; log operator có dòng `refusing to replicate from it`. Nguyên nhân là một Pod (thường là ordinal 0) rỗng được chọn làm master, trong khi Pod khác có dữ liệu. Operator giữ nguyên thiết lập để tránh mất dữ liệu.

Cách xử lý:

```bash
# Tìm Pod có dữ liệu. Thay các giá trị dưới đây bằng Pod thực tế.
for ORD in 0 1 2; do
  echo "pod $ORD: DBSIZE=$(rcli "$ORD" DBSIZE)"
done

# Giả sử redis-sentinel-2 có dữ liệu. Trỏ các Pod rỗng vào nó (dữ liệu của Pod rỗng sẽ bị ghi đè bởi đồng bộ từ master).
M="redis-sentinel-2.redis-sentinel-headless.${NAMESPACE}.svc.cluster.local"
for ORD in 0 1; do
  rcli "$ORD" REPLICAOF "$M" 6379
done
```

Chỉ làm khi Pod rỗng có `DBSIZE=0`. Không làm khi cả hai Pod đều có dữ liệu khác nhau. Sau đó chạy `bash redis-sentinel/check-master.sh` để xác nhận.

## Giao diện RedisInsight

Để duyệt key, chạy Workbench và kiểm tra failover qua giao diện, triển khai RedisInsight theo [`../redisinsight/README.md`](../redisinsight/README.md). RedisInsight dùng connection type Sentinel, TLS CA và master group `mymaster`; không kết nối cổng `26379` như một Redis database thông thường.

## Lưu ý vận hành

- Redis replication bất đồng bộ nên có thể mất write gần thời điểm failover.
- EBS volume gắn với một AZ; Pod không thể tự chuyển PVC cũ sang AZ khác khi cả AZ mất. `Retain` trên StorageClass giữ EBS khi PV bị xóa, nhưng operator vẫn xóa PVC khi xóa `RedisReplication`. Xem cảnh báo ở phần Restore.
- Khi Redis chạm `maxmemory` 1 GB với `noeviction`, write trả lỗi; điều chỉnh sizing theo workload.
- cert-manager gia hạn `redis-sentinel-tls`, nhưng Redis/Sentinel có thể cần restart tuần tự để nạp chứng chỉ mới. CA dài hạn `redis-sentinel-ca` cần backup và kế hoạch xoay vòng riêng.
- Trước production, thử mất primary, restart node và restore hoàn chỉnh trên môi trường tương đương; xác nhận client luôn tìm đúng primary sau failover.

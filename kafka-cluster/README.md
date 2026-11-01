# Kafka Cluster HA trên EKS với Strimzi

Bộ file này cài **Strimzi cluster operator 1.3.0** và tạo cụm Kafka **4.3.1 chạy KRaft** gồm **6 node** (mỗi node vừa controller vừa broker), phân bổ **2 node mỗi AZ trên 3 AZ**. Mỗi node dùng PVC EBS gp3 mã hóa riêng. Topic mặc định có 3 replica, một replica mỗi AZ, và `min.insync.replicas=2`: cụm chịu được mất một node hoặc một AZ mà producer `acks=all` vẫn ghi được. Kafka Connect chạy 3 worker trên node group riêng (`workload=kafka-connect`, mỗi AZ một worker), với plugin Debezium PostgreSQL trong image [images/kafka-connect-postgres/](images/kafka-connect-postgres/Dockerfile).

Cấu trúc và cách làm theo [Elasticsearch HA](../elasticsearch/ELASTICSEARCH.md): operator cài bằng Helm, node group riêng có label `workload=kafka`, preflight bằng [check.sh](check.sh), và secret không commit vào git.

## Các file

| File | Vai trò |
| --- | --- |
| `namespace.yaml` | Tạo `kafka` cho cụm và `kafka-system` cho Strimzi operator. |
| `storage-class.yaml` | StorageClass `kafka-gp3` (EBS CSI, mã hóa, `Retain`, `WaitForFirstConsumer`). |
| `strimzi-values.yaml` | Giá trị Helm cho operator: theo dõi namespace `kafka`, 2 replica, PDB. |
| `kafka.yaml` | Kafka CR: listener TLS + mTLS, rack awareness theo zone, cấu hình replication, Entity Operator. |
| `kafka-nodepool.yaml` | KafkaNodePool `combined`: 6 Pod, roles controller + broker, PVC `kafka-gp3` 100Gi, ràng buộc node và AZ. |
| `kafka-connect-user.yaml` | KafkaUser `kafka-connect` (mTLS) với ACL cho topic nội bộ và topic `pg.*`. |
| `kafka-topics-connect.yaml` | KafkaTopic cho `connect-configs`, `connect-offsets`, `connect-status`. |
| `postgres-orders-topic.yaml` | KafkaTopic `pg.public.orders.v1.0.0` và heartbeat `__debezium-heartbeat.pg`; cần khai báo vì cluster tắt auto-create topic. |
| `kafka-connect.yaml` | KafkaConnect `kafka-connect`: 3 worker, image Debezium PostgreSQL, rack awareness. |
| `postgres-cdc-credentials.secret.yaml.example` | Mẫu Secret chứa hostname, port, dbname và user/password PostgreSQL. File thật bị `.gitignore`. |
| `kafka-connector-postgres.yaml` | Mẫu KafkaConnector Debezium PostgreSQL |
| `kafka-backup-user.yaml` | Hai KafkaUser mTLS least-privilege: backup chỉ đọc topic `v1.0.0`; restore chỉ ghi đúng topic `v2.0.0`. |
| `kafka-backup-configmap.yaml` | Script/config backup S3, deep validation và restore có topic mapping cách ly. |
| `kafka-backup-cronjob.yaml` | ServiceAccount dùng EKS Pod Identity và CronJob backup hàng ngày lúc 02:00 (Asia/Ho_Chi_Minh). |
| `kafka-restore-test-topics.yaml` | Hai KafkaTopic `v2.0.0` dùng cho restore drill, không ghi đè topic production `v1.0.0`. |
| `kafka-restore-job.yaml` | Job restore một backup ID từ topic `v1.0.0` trên S3 vào topic `v2.0.0`. |
| `check.sh` | Preflight: 6 node kafka Ready, 3 AZ, tối thiểu 2 node mỗi AZ, EBS CSI, StorageClass. |
| `images/kafka-connect-postgres/Dockerfile` | Image Connect trên nền `quay.io/strimzi/kafka:1.3.0-kafka-4.3.1` + plugin Debezium 3.5.2.Final. |

## Thiết kế chính

- **6 node kết hợp controller + broker** (không tách controller riêng): quorum controller là 4/6, nên mất một AZ (2 Pod) vẫn giữ quorum. Đây là cách làm tương đương với 6 node master-eligible của Elasticsearch. Nếu muốn cô lập metadata khỏi tải dữ liệu, có thể tách 3 controller riêng: khi đó cụm có 9 Pod.
- **Node group tách riêng cho Connect**: Pod Connect chạy trên `workload=kafka-connect`, không chung node với broker, để Debezium (snapshot, lag) không cạnh tranh CPU/RAM với broker. Có thể scale hoặc nâng cấp node Connect độc lập.
- **Rack awareness**: Strimzi gắn `broker.rack` theo nhãn `topology.kubernetes.io/zone` của node. Replica của một partition nằm ở ba AZ khác nhau.
- **Durability**: `default.replication.factor=3`, `min.insync.replicas=2`, `unclean.leader.election.enable=false`, `auto.create.topics.enable=false`. Producer cần `acks=all` để được hưởng lợi từ min ISR.
- **Không mở listener ra ngoài**: chỉ có listener `tls` nội bộ (port 9093), client xác thực bằng chứng chỉ mTLS của KafkaUser. Khi cần truy cập từ ngoài cluster, thêm listener riêng và làm lại bảo mật.
- **Dữ liệu an toàn khi xóa**: `deleteClaim: false` và StorageClass `Retain`. Xóa Kafka CR không xóa EBS volume.
- **Image pin cứng**: Strimzi 1.3.0, Kafka 4.3.1 (`metadataVersion: 4.3-IV0`), Debezium 3.5.2.Final. Nâng cấp là thay đổi có chủ đích, không làm tự động.

## Điều kiện trước khi cài

- Đã apply `terraform/00-networking`, `terraform/01.kubernetes` và `terraform/database` (RDS PostgreSQL Multi-AZ cho Debezium, xem mục 3). Với `terraform/01.kubernetes`: node group `kafka` (6 node `m6i.xlarge`, desired 6, min 6, max 9, trải 3 private subnet), node group `kafka-connect` (3 node `m6i.large`, desired 3, min 3, max 6, mỗi AZ một node), EBS CSI driver và Pod Identity Agent. Node group này khai báo trong [01.nodes.tf](../terraform/01.kubernetes/01.nodes.tf).
- Máy chạy lệnh có `kubectl`, `jq`, Helm 3 và `docker` (để build image Connect). Truy cập được `oci://quay.io` và `quay.io`.
- `KUBE_CONTEXT` trỏ đúng cluster:

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl config get-contexts
kubectl --context "$KUBE_CONTEXT" get nodes -L workload -L topology.kubernetes.io/zone
```

## Kiểm tra trước khi cài

Chạy từ thư mục gốc repo. Script chỉ đọc Kubernetes API:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
bash kafka-cluster/check.sh
```

Nếu script báo thiếu StorageClass `kafka-gp3`, chạy bước tiếp theo rồi kiểm tra lại.

## Cài Strimzi operator

Kiểm tra CRD chưa tồn tại hoặc thuộc release này. Helm không nâng cấp CRD khi `helm upgrade`, nên phải kiểm tra trước khi cài lại:

```bash
kubectl --context "$KUBE_CONTEXT" get crd | grep kafka.strimzi.io || echo "Chưa có CRD Strimzi"
```

```bash
set -euo pipefail

kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/storage-class.yaml

helm --kube-context "$KUBE_CONTEXT" upgrade --install strimzi-kafka-operator \
  oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --version 1.3.0 \
  --namespace kafka-system \
  -f kafka-cluster/strimzi-values.yaml \
  --wait --timeout 10m

kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/kafkas.kafka.strimzi.io --timeout=120s
kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/kafkanodepools.kafka.strimzi.io --timeout=120s

kubectl --context "$KUBE_CONTEXT" -n kafka-system get pods -l strimzi.io/kind=cluster-operator
```

## Tạo cụm Kafka

Apply Kafka CR và node pool cùng lúc. Strimzi ghép node pool vào cụm nhờ label `strimzi.io/cluster: kafka-cluster`:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-nodepool.yaml

kubectl --context "$KUBE_CONTEXT" -n kafka wait kafka/kafka-cluster \
  --for=condition=Ready --timeout=20m
```

## Kiểm tra sau khi cài

```bash
# 6 Pod, mỗi Pod một node; cột ZONE phải có hai Pod mỗi zone.
kubectl --context "$KUBE_CONTEXT" -n kafka get pods -l strimzi.io/cluster=kafka-cluster \
  -o wide -L topology.kubernetes.io/zone

# 6 PVC, mỗi PVC 100Gi, class kafka-gp3.
kubectl --context "$KUBE_CONTEXT" -n kafka get pvc

# Rack của broker: broker.rack đọc từ /opt/kafka/init/rack.id (init container ghi theo zone của node).
# Giá trị phải khớp cột ZONE của Pod tương ứng.
kubectl --context "$KUBE_CONTEXT" -n kafka exec kafka-cluster-combined-0 -c kafka -- \
  cat /opt/kafka/init/rack.id; echo

# ClusterRoleBinding cho broker đọc nhãn zone của node; Strimzi tạo khi bật rack.
kubectl --context "$KUBE_CONTEXT" get clusterrolebinding -o name | grep -i kafka

kubectl --context "$KUBE_CONTEXT" -n kafka get kafka kafka-cluster \
  -o jsonpath='{.status.kafkaVersion}{"\n"}{.status.conditions}{"\n"}'
```

Tên Pod theo mẫu `kafka-cluster-combined-<id>`. Không coi `<id>` là leader; role của broker thay đổi theo quorum.

## Kafka Connect và Debezium PostgreSQL

### 1. Build và push image Connect

Image này đặt tên theo tag trong `kafka-connect.yaml`. Push là thao tác công khai, chạy khi đã đăng nhập đúng registry:

```bash
docker buildx build --platform linux/amd64 -t thoaiky1992/kafka-connect-postgres:3.5.2.Final-kafka-4.3.1 kafka-cluster/images/kafka-connect-postgres

# Kiểm tra plugin trước khi push: PostgresConnector phải có isLoadable=true.
docker run --rm --entrypoint /opt/kafka/bin/connect-plugin-path.sh \
  thoaiky1992/kafka-connect-postgres:3.5.2.Final-kafka-4.3.1 \
  list --plugin-location /opt/kafka/plugins | grep PostgresConnector

docker push thoaiky1992/kafka-connect-postgres:3.5.2.Final-kafka-4.3.1
```

Khi đổi base Strimzi hoặc phiên bản Debezium, build lại image và cập nhật tag trong `kafka-connect.yaml`.

### 2. Tạo user và topic nội bộ

```bash
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-connect-user.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-topics-connect.yaml

# Secret kafka-connect do Strimzi tạo; KafkaConnect cần Secret này khi Pod khởi động.
kubectl --context "$KUBE_CONTEXT" -n kafka wait kafkauser/kafka-connect \
  --for=condition=Ready --timeout=5m
```

### 3. Tạo RDS và chuẩn bị PostgreSQL

#### 3a. Tạo RDS PostgreSQL Multi-AZ bằng Terraform

RDS, subnet group, security group và parameter group được tạo bởi tầng [terraform/database](../terraform/database/README.md). Tầng này phải apply sau `00-networking`:

```shell
terraform -chdir=terraform/03.database init -backend-config=backend.tfvars -migrate-state
terraform -chdir=terraform/03.database apply -var-file=terraform.tfvars
terraform -chdir=terraform/03.database output -json values | jq '.rds'
```

Terraform tạo hai cụm Multi-AZ: RDS instance (`values.rds`) và Multi-AZ DB cluster (`values.rds_cluster`). Chọn **một** cụm làm nguồn CDC và dùng endpoint của nó: `rds.endpoint` cho instance, `rds_cluster.writer_endpoint` cho cluster. Điền endpoint vào `database.hostname` và `database_name` vào `database.dbname` trong `postgres-cdc-credentials.secret.yaml`. Tên SSM parameter chứa mật khẩu user master nằm ở `master_password_parameter` (dùng ở bước 3c).

#### 3b. Cấu hình cần thiết và ý nghĩa

| Cấu hình | Đặt ở đâu | Giá trị | Vì sao cần |
| --- | --- | --- | --- |
| `wal_level = logical` | Parameter group (`rds.logical_replication = 1`): DB parameter group cho instance, cluster parameter group cho cluster | Terraform tạo sẵn | Debezium đọc thay đổi từ WAL qua `pgoutput`, cần mức logical. Tham số static: chỉ có hiệu lực khi tạo mới hoặc sau reboot. |
| Multi-AZ | `multi_az = true` (instance) hoặc Multi-AZ DB cluster | Bật | RDS giữ standby đồng bộ ở AZ khác và failover tự động, endpoint giữ nguyên. Rủi ro: replication slot của Debezium có thể không còn trên primary mới, xem ghi chú bên dưới bảng. |
| Mật khẩu master | `random_string` lưu trong SSM `SecureString` | Terraform tạo sẵn | Dùng chung cho instance và cluster. Đọc từ `master_password_parameter` khi cần. |
| Ingress 5432 | Security group RDS | Chỉ private subnet | Pod Kafka Connect chạy trong private subnet. RDS không có public endpoint. |
| `rds_replication` | Role PostgreSQL của user `debezium` | Được cấp | Quyền replication logical trên RDS, không cần `rds_superuser`. |
| `SELECT` trên bảng | Quyền của user `debezium` | Các bảng trong `table.include.list` | Snapshot ban đầu (`snapshot.mode: initial`) đọc dữ liệu hiện có. |
| `CREATE` trên database và owner của bảng | Quyền của user `debezium` | Khi dùng `filtered` | Connector tạo publication `debezium_cdc_pub` với bảng trong danh sách. |
| `database.sslmode: verify-full` | KafkaConnector | Không tắt verify | Xác thực chứng chỉ server RDS, không gửi mật khẩu tới server không xác thực được. |
| `publication.autocreate.mode: filtered` | KafkaConnector | Mẫu hiện tại | Debezium tự tạo publication. Đổi thành `disabled` nếu admin tạo publication thủ công. |

Ghi chú về failover: replication slot là trạng thái của primary. Nếu slot không có trên primary mới sau failover, connector sẽ báo lỗi, phải xóa connector, tạo lại slot và snapshot lại. Kiểm tra hành vi này trên môi trường dev trước khi dựa vào nó (chi tiết trong [terraform/database/README.md](../terraform/database/README.md)).

#### 3c. Tạo user Debezium trong PostgreSQL

RDS nằm trong private subnet, nên `psql` phải chạy từ máy có đường vào VPC (VPN, bastion hoặc SSM port-forward). Đăng nhập bằng user master, lấy mật khẩu từ SSM Parameter Store (`master_password_parameter` trong output):

```shell
export PGPASSWORD="$(aws ssm get-parameter --region ap-southeast-1 \
  --name "<master_password_parameter>" --with-decryption \
  --query Parameter.Value --output text)"

# CA của RDS dùng khi admin kết nối thủ công, tải về máy admin, không đưa vào repo.
curl -fsSo /tmp/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

psql "host=<endpoint> port=5432 dbname=<database> user=postgres_admin sslmode=verify-full sslrootcert=/tmp/rds-global-bundle.pem"
```

Trong `psql`, chạy các lệnh sau (thay `app` bằng `database_name` từ output, nếu khác). Đặt mật khẩu mạnh cho `<password>` và đưa đúng mật khẩu đó vào Secret ở bước 4:

```sql
CREATE USER debezium WITH PASSWORD '<password>';

-- Quyền replication logical trên RDS (role do RDS cung cấp).
GRANT rds_replication TO debezium;

GRANT CONNECT ON DATABASE app TO debezium;
GRANT USAGE ON SCHEMA public TO debezium;
GRANT SELECT ON TABLE public.orders TO debezium;  -- thêm cho mỗi bảng trong table.include.list
```

Với `publication.autocreate.mode: filtered`, PostgreSQL yêu cầu user có quyền `CREATE` trên database và là owner của bảng đưa vào publication:

```sql
GRANT CREATE ON DATABASE app TO debezium;
ALTER TABLE public.orders OWNER TO debezium;
ALTER TABLE public.orders REPLICA IDENTITY FULL;
```

Nếu không muốn đổi owner của bảng ứng dụng, tạo publication trước bằng user master: `CREATE PUBLICATION debezium_cdc_pub FOR TABLE public.orders;`, rồi đặt `publication.autocreate.mode: disabled` trong `kafka-connector-postgres.yaml`.

Kiểm tra (chạy bằng user master):

```sql
SHOW wal_level;                                                    -- phải là: logical
SELECT pg_has_role('debezium', 'rds_replication', 'member');       -- phải là: t
```

Đóng phiên admin, xóa biến mật khẩu và file bundle khi không còn dùng:

```shell
unset PGPASSWORD
rm -f /tmp/rds-global-bundle.pem
```

#### 3d. Ghi chú TLS

PostgreSQL JDBC cần file CA khi dùng `database.sslmode: verify-full`; JVM truststore mặc định không thay thế cho `database.sslrootcert`. Tải bundle chính thức của Amazon RDS và tạo ConfigMap trước khi apply `KafkaConnect`:

```bash
curl -fsSLo /tmp/rds-global-bundle.pem \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

kubectl --context "$KUBE_CONTEXT" -n kafka create configmap rds-ca-bundle \
  --from-file=global-bundle.pem=/tmp/rds-global-bundle.pem \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -

rm -f /tmp/rds-global-bundle.pem
```

`kafka-connect.yaml` mount ConfigMap tại `/mnt/rds-ca`; connector đặt `database.sslrootcert: /mnt/rds-ca/global-bundle.pem`. CA là public nhưng không đưa bản sao vào repo để tránh bundle lỗi thời. Không tắt xác minh bằng `sslmode=require` hoặc `disable`.

### 4. Tạo Secret credential

```bash
cp kafka-cluster/postgres-cdc-credentials.secret.yaml.example \
   kafka-cluster/postgres-cdc-credentials.secret.yaml
chmod 600 kafka-cluster/postgres-cdc-credentials.secret.yaml
${EDITOR:-vi} kafka-cluster/postgres-cdc-credentials.secret.yaml

kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/postgres-cdc-credentials.secret.yaml
```

File `postgres-cdc-credentials.secret.yaml` được `.gitignore` trong `kafka-cluster/`. Kiểm tra `git status` trước khi commit.

Secret chứa năm key trong `postgres.properties`: `database.hostname`, `database.port`, `database.dbname`, `database.user` và `database.password`. KafkaConnect mount file này tại `/mnt/postgres-cdc-credentials/postgres.properties`; KafkaConnector đọc từng giá trị qua `FileConfigProvider` thay vì lưu trực tiếp trong CR.

### 5. Triển khai Connect và connector

```bash
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/postgres-orders-topic.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-connect.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka wait kafkaconnect/kafka-connect \
  --for=condition=Ready --timeout=15m

kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-connector-postgres.yaml

kubectl --context "$KUBE_CONTEXT" -n kafka get kafkaconnector postgres-cdc \
  -o jsonpath='{.status.connectorStatus}{"\n"}'
```

Kiểm tra trạng thái task qua REST API của Connect (chỉ truy cập nội bộ qua port-forward):

```bash
kubectl --context "$KUBE_CONTEXT" -n kafka port-forward svc/kafka-connect-connect-api 8083:8083 &
curl -s localhost:8083/connectors/postgres-cdc/status | jq .
kill %1
```

Nếu connector đang ở `FAILED`, đọc log Pod `kafka-connect-connect-*` trước khi restart.

## Backup topic lên S3 và restore

Backup dùng `osodevops/kafka-backup` 0.26.1 được pin bằng image digest, kết nối Kafka qua mTLS và truy cập S3 bằng EKS Pod Identity; không có AWS access key trong manifest. Hạ tầng S3/IAM nằm trong [15.kafka-cluster-backup.tf](../terraform/01.kubernetes/15.kafka-cluster-backup.tf): bucket private, chặn public access, versioning, mã hóa SSE-S3, bắt buộc TLS và lifecycle 30 ngày. `force_destroy=false` ngăn `terraform destroy` xóa âm thầm các bản backup còn trong bucket.

### Quy ước version topic

Topic dùng SemVer ở cuối tên: `<logical-topic>.v<major>.<minor>.<patch>`. Mỗi tên/version là một topic Kafka độc lập và bất biến; Kafka không hỗ trợ rename topic.

- Production hiện tại: `order-service.v1.0.0`, `pg.public.orders.v1.0.0`.
- Restore drill/ứng viên cutover: `order-service.v2.0.0`, `pg.public.orders.v2.0.0`.
- Một bản vá contract cùng major có thể dùng `order-service.v1.0.2`, `pg.public.orders.v1.0.2`; phải tạo KafkaTopic và mapping mới, không sửa `topicName` của KafkaTopic cũ.

Khi tăng version, cập nhật đồng bộ producer/consumer, Debezium `RegexRouter`, KafkaTopic, ACL backup/restore, danh sách backup và `topic_mapping`. Không tái sử dụng một topic version cũ cho dữ liệu có contract khác.

#### Chuyển từ topic cũ sang `v1.0.0`

Apply manifest mới chỉ **tạo topic version mới**, không đổi tên hoặc tự copy dữ liệu từ `order-service`/`pg.public.orders`. Thực hiện migration theo thứ tự:

1. Tạo `order-service.v1.0.0` và `pg.public.orders.v1.0.0` bằng hai manifest KafkaTopic.
2. Nếu cần giữ lịch sử, pause writer rồi dùng một restore/copy job chuyển dữ liệu từ topic cũ sang `v1.0.0`; không restore vào topic đích đã có dữ liệu.
3. Đổi producer/consumer của order service sang `order-service.v1.0.0`.
4. Apply KafkaConnector có `RegexRouter` để các CDC event mới đi vào `pg.public.orders.v1.0.0`, rồi kiểm tra connector `RUNNING` và record mới xuất hiện đúng topic.
5. Chỉ sau khi cả hai topic `v1.0.0` tồn tại và đã được kiểm tra mới apply ACL/config backup mới và tạo backup đầu tiên.
6. Giữ topic cũ trong thời gian rollback; xóa sau khi consumer mới ổn định và hết thời hạn lưu giữ đã thống nhất.

Các backup đã tạo trước migration vẫn chứa tên topic cũ. Không dùng trực tiếp chúng với mapping `v1.0.0 → v2.0.0`; cần restore config chuyển tiếp map tên cũ sang version đích tương ứng.

Phạm vi backup hiện tại chỉ gồm hai topic dữ liệu cần thiết:

- `order-service.v1.0.0`
- `pg.public.orders.v1.0.0`

Không backup `connect-configs`, `connect-offsets`, `connect-status`, heartbeat, `__consumer_offsets` hoặc các internal topic. Vì vậy consumer-group offsets không được khôi phục; manifest Kubernetes, KafkaTopic, KafkaUser và connector tiếp tục được quản lý bằng Git/Terraform.

### 1. Tạo hạ tầng S3/IAM và triển khai CronJob

```bash
terraform -chdir=terraform/01.kubernetes init -backend-config=backend.tfvars -migrate-state
terraform -chdir=terraform/01.kubernetes apply -var-file=terraform.tfvars

kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-backup-user.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-backup-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-backup-cronjob.yaml

kubectl --context "$KUBE_CONTEXT" -n kafka wait \
  kafkauser/kafka-backup kafkauser/kafka-restore \
  --for=condition=Ready --timeout=5m
kubectl --context "$KUBE_CONTEXT" -n kafka get cronjob/dev-demo-kafka-cluster-backup
```

CronJob chạy lúc `02:00` mỗi ngày theo `Asia/Ho_Chi_Minh`, dùng `concurrencyPolicy: Forbid`. Mỗi lần chạy tạo snapshot đến end offsets tại thời điểm bắt đầu, nén Zstandard, ghi dưới `s3://dev-demo-kafka-cluster-backup/kafka-cluster/<backup-id>/`, rồi chạy `validate --deep`. Job chỉ thành công khi segment, checksum và tính liên tục của offsets đều hợp lệ.

### 2. Chạy và kiểm tra một backup thủ công

```bash
BACKUP_JOB="dev-demo-kafka-cluster-backup-manual-$(date -u +%H%M%S)"
kubectl --context "$KUBE_CONTEXT" -n kafka create job \
  --from=cronjob/dev-demo-kafka-cluster-backup "$BACKUP_JOB"

kubectl --context "$KUBE_CONTEXT" -n kafka wait "job/$BACKUP_JOB" \
  --for=condition=complete --timeout=30m
kubectl --context "$KUBE_CONTEXT" -n kafka logs "job/$BACKUP_JOB"

aws s3 ls s3://dev-demo-kafka-cluster-backup/kafka-cluster/ --recursive
```

Log cuối phải có `Result: VALID`, `Segments Missing: 0`, `Segments Corrupted: 0` và `Data Gaps: 0`. Lấy `backup_id` từ dòng `Starting backup`, ví dụ `daily-20261104T065520Z`.

### 3. Restore drill an toàn

Job mặc định chỉ restore theo mapping sau, không đụng topic nguồn:

| Nguồn trong backup | Đích restore drill |
| --- | --- |
| `order-service.v1.0.0` | `order-service.v2.0.0` |
| `pg.public.orders.v1.0.0` | `pg.public.orders.v2.0.0` |

Mỗi drill phải dùng topic test rỗng; nếu topic test đã tồn tại từ lần trước, lệnh xóa dưới đây sẽ xóa dữ liệu test cũ. Không đổi tên thành topic production nếu chưa có kế hoạch cutover riêng.

```bash
export BACKUP_ID="daily-YYYYMMDDTHHMMSSZ"

kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  -f kafka-cluster/kafka-restore-test-topics.yaml --ignore-not-found=true
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-restore-test-topics.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka wait \
  kafkatopic/order-service-v2-0-0 kafkatopic/pg-public-orders-v2-0-0 \
  --for=condition=Ready --timeout=5m

kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  job/dev-demo-kafka-cluster-restore-v2 --ignore-not-found=true
sed "s/REPLACE_BACKUP_ID/${BACKUP_ID}/" kafka-cluster/kafka-restore-job.yaml | \
  kubectl --context "$KUBE_CONTEXT" apply -f -

kubectl --context "$KUBE_CONTEXT" -n kafka wait \
  job/dev-demo-kafka-cluster-restore-v2 \
  --for=condition=complete --timeout=30m
kubectl --context "$KUBE_CONTEXT" -n kafka logs \
  job/dev-demo-kafka-cluster-restore-v2
```

Restore luôn chạy `validate-restore` trước khi produce. Log thành công phải có `Status: ✓ VALID`, đúng số record dự kiến và `Restore completed successfully`. Sau đó đối chiếu end offsets, số message và nội dung giữa topic `v1.0.0` với `v2.0.0`; không chỉ dựa vào trạng thái `Complete` của Job.

Sau khi chuyển sang tên có version, phải tạo backup mới chứa đúng topic `v1.0.0` rồi mới chạy drill `v1.0.0 → v2.0.0`. Backup cũ chứa tên không có version không tự động tương thích với mapping mới; nếu cần dùng phải tạo restore config chuyển tiếp riêng.

### 4. Khôi phục sự cố thật

Kafka không hỗ trợ rename topic trực tiếp hoặc cutover topic một cách nguyên tử. Không restore vào topic đang có dữ liệu vì record được append và có thể tạo duplicate. Cũng không xóa topic cũ ngay sau restore: giữ nó làm đường rollback cho đến khi topic mới đã được kiểm chứng.

#### Phương án A — blue/green topic (khuyến nghị)

1. Chọn version đích mới, ví dụ `order-service.v2.0.0` và `pg.public.orders.v2.0.0`.
2. Tạo topic recovery với cùng partition count, replication factor và config của topic nguồn. Không giảm partition count.
3. Tạo ACL cho `kafka-restore` chỉ trên đúng hai topic version đích; không mở quyền ghi wildcard hoặc quyền ghi topic production lâu dài.
4. Kiểm tra `restore.topic_mapping` trong `kafka-backup-configmap.yaml` map đúng version nguồn sang version đích, apply lại ConfigMap và chạy `validate-restore` trước khi restore.
5. Restore backup, sau đó đối chiếu partition/end offset, record count, schema, checksum và chạy consumer thử trên topic recovery.
6. Trước cutover, dừng producer `order-service.v1.0.0`, pause Debezium connector và dừng consumer liên quan. Nếu cluster nguồn vẫn dùng được, tạo thêm một backup cuối sau khi đã dừng ghi để giảm khoảng mất dữ liệu.
7. Chuyển cấu hình producer/consumer sang topic recovery. Dùng consumer group mới hoặc lập kế hoạch reset offsets; không tái sử dụng offset cũ một cách mù quáng vì offsets của topic mới có thể khác.
8. Theo dõi lỗi, lag và dữ liệu nghiệp vụ. Giữ topic cũ trong thời gian rollback đã thống nhất, sau đó mới xóa và thu hồi ACL tạm.

Ví dụ mapping recovery (chỉ là mẫu; phải tạo topic và ACL tương ứng trước khi chạy):

```yaml
restore:
  topic_mapping:
    order-service.v1.0.0: order-service.v2.0.0
    pg.public.orders.v1.0.0: pg.public.orders.v2.0.0
  strip_offset_headers: true
  produce_acks: -1
```

#### Phương án B — bắt buộc giữ nguyên tên topic

Chỉ dùng khi ứng dụng không thể đổi tên topic và đã chấp nhận downtime:

1. Dừng toàn bộ producer, Debezium connector và consumer của topic cần phục hồi.
2. Chạy backup cuối nếu nguồn còn đọc được, rồi bắt buộc `validate --deep` và `validate-restore`.
3. Ghi lại partition count, replication factor và toàn bộ topic config hiện tại.
4. Xóa topic cũ và chờ Kafka/Strimzi xác nhận topic đã biến mất hoàn toàn. Đây là bước phá hủy dữ liệu và không có rename/rollback nguyên tử.
5. Tạo lại topic rỗng với đúng tên, partition count, replication factor và config đã ghi nhận.
6. Đổi mapping để nguồn restore về đúng tên gốc (hoặc bỏ mapping nếu công cụ giữ nguyên tên), cấp ACL ghi tạm thời, rồi restore.
7. Đối chiếu dữ liệu, xử lý consumer offsets, khởi động lại consumer trước rồi mới mở producer/connector theo change plan.
8. Thu hồi ngay ACL ghi production của user restore sau khi hoàn tất.

Với sự cố mất cả cluster, phương án sạch nhất là restore vào một cluster DR rỗng với tên topic gốc, kiểm chứng, rồi chuyển bootstrap servers của ứng dụng sang cluster DR. Cách này tránh xóa topic production trong lúc đang phục hồi.

Consumer-group offsets không nằm trong backup hiện tại vì `__consumer_offsets` bị loại trừ. Sau cutover cần dùng group mới để replay từ đầu/offset đã chọn, hoặc tạo và duyệt một offset-reset plan riêng. RPO thực tế là thời điểm kết thúc của backup gần nhất; backup hàng ngày không thay thế replication liên tục nếu yêu cầu RPO gần bằng 0.

### 5. Dọn dữ liệu restore drill

Chỉ chạy sau khi đã kiểm tra xong; các lệnh này xóa Job và **hai topic test**, không xóa topic production hay dữ liệu S3:

```bash
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  job/dev-demo-kafka-cluster-restore-v2 --ignore-not-found=true
kubectl --context "$KUBE_CONTEXT" delete \
  -f kafka-cluster/kafka-restore-test-topics.yaml --ignore-not-found=true
```

## Vận hành

- **Rolling restart**: PDB `maxUnavailable: 1` (Strimzi tạo tự động) chỉ cho phép một broker xuống tại một thời điểm. Không xóa nhiều Pod broker cùng lúc.
- **Không giảm replicas dưới 6** và không đổi zone của node. Với 6 broker, RF=3 và min ISR=2 vẫn chịu được mất một AZ; giảm xuống dưới 6 sẽ làm mất ràng buộc này.
- **Nâng cấp**: nâng Strimzi trước, sau đó nâng `version` của Kafka (hoặc image Connect) từng bước theo ma trận tương thích của Strimzi. Với Kafka thay đổi `metadataVersion` là thay đổi không đảo ngược được; làm trên môi trường thử trước.
- **Xóa cụm**: `deleteClaim: false` giữ PVC; `Retain` giữ EBS volume. Sau khi chắc chắn không còn dữ liệu cần giữ, xóa PVC và EBS volume bằng tay.
- **Dung lượng**: 100Gi mỗi broker chỉ là giá trị khởi đầu. Tính theo throughput × retention × RF, rồi tăng `size` trong `kafka-nodepool.yaml` (`allowVolumeExpansion: true`).
- **Sao lưu**: theo dõi trạng thái CronJob và cảnh báo khi job thất bại hoặc không chạy đúng lịch; thực hiện restore drill định kỳ. S3 backup bảo vệ dữ liệu lịch sử, nhưng không thay thế MirrorMaker 2/cluster DR nếu cần RPO gần bằng 0.

## Chưa bao gồm trong bộ file này

- Metrics (JMX exporter, kafka-exporter) và dashboard. Cần `metricsConfig` riêng trước khi đưa vào production.
- Cruise Control (cân bằng partition sau khi thêm broker).
- Listener cho client ngoài cluster, NetworkPolicy, và Schema Registry.
- Quản lý user/ACL cho ứng dụng khác: thêm KafkaUser theo mẫu `kafka-connect-user.yaml`.

## Gỡ cài đặt theo thứ tự ngược

Trước khi gỡ, kiểm tra backup S3 gần nhất và gỡ Kafka UI theo [`../kafka-ui/README.md`](../kafka-ui/README.md). Không uninstall Strimzi hoặc xóa namespace trước khi KafkaTopic/KafkaUser đã hết finalizer; làm sai thứ tự có thể khiến namespace kẹt `Terminating`.

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"

# 1. Dừng backup/restore và workload phụ thuộc Kafka.
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  cronjob/dev-demo-kafka-cluster-backup --ignore-not-found=true
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  job/dev-demo-kafka-cluster-restore-v2 --ignore-not-found=true
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  kafkaconnector/postgres-cdc --ignore-not-found=true --wait=true
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  kafkaconnect/kafka-connect --ignore-not-found=true --wait=true

# 2. Topic/User CR phải được Topic/User Operator finalize khi Kafka cluster còn chạy.
kubectl --context "$KUBE_CONTEXT" -n kafka delete kafkatopic --all \
  --wait=true --timeout=10m
kubectl --context "$KUBE_CONTEXT" -n kafka delete kafkauser --all \
  --wait=true --timeout=10m

# 3. Xóa Kafka CR; deleteClaim=false giữ PVC.
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  kafka/kafka-cluster --ignore-not-found=true --wait=true
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  kafkanodepool/combined --ignore-not-found=true --wait=true

# 4. Dọn resource backup còn lại.
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  configmap/dev-demo-kafka-cluster-backup \
  serviceaccount/dev-demo-kafka-cluster-backup --ignore-not-found=true
```

Kiểm tra không còn CR/finalizer rồi mới uninstall operator:

```bash
kubectl --context "$KUBE_CONTEXT" -n kafka get \
  kafka,kafkanodepool,kafkaconnect,kafkaconnector,kafkatopic,kafkauser

helm --kube-context "$KUBE_CONTEXT" uninstall strimzi-kafka-operator \
  --namespace kafka-system --ignore-not-found --wait
kubectl --context "$KUBE_CONTEXT" delete namespace kafka-system \
  --ignore-not-found=true --wait=true
```

Nếu muốn giữ PVC để phục hồi, giữ namespace `kafka`, PVC và StorageClass `kafka-gp3`. Nếu muốn xóa hoàn toàn:

```bash
kubectl --context "$KUBE_CONTEXT" delete namespace kafka \
  --ignore-not-found=true --wait=true
kubectl --context "$KUBE_CONTEXT" get pv \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,CLAIM:.spec.claimRef.name'
kubectl --context "$KUBE_CONTEXT" delete storageclass kafka-gp3 \
  --ignore-not-found=true
```

PV/EBS dùng `Retain`, nên xóa namespace chỉ làm PV chuyển `Released`; volume vẫn tồn tại và tính phí. Bucket S3/IAM/Pod Identity do Terraform quản lý không bị các lệnh trên xóa; `force_destroy=false` cũng ngăn xóa bucket còn dữ liệu. Nếu namespace đã kẹt, ưu tiên khôi phục operator để finalizer chạy; chỉ patch finalizer trên từng CR sau khi đã chấp nhận bỏ quá trình cleanup của operator, không force-finalize cả namespace trước.

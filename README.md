# PostgreSQL, Redis, Kafka và Elasticsearch HA trên Kubernetes

Bộ cấu hình này dùng Helm để cài **CloudNativePG, OpsTree Redis Operator, Strimzi và Elastic ECK**. Mỗi dịch vụ dữ liệu có 3 pod trên 3 node khác nhau và PVC riêng. PostgreSQL dùng primary + 2 standby; Redis dùng replication + 3 Sentinel; Kafka dùng 3 broker/controller KRaft; Elasticsearch dùng 3 node. Mỗi operator chạy 2 replica trên các node khác nhau. Phiên bản chart nằm trong file `config/<dịch-vụ>.env` tương ứng.

## Yêu cầu

- Kubernetes có ít nhất **3 worker node Ready**, có thể lập lịch pod; phiên bản Kubernetes **1.30+** cho Strimzi 1.2.0. Control plane và lưu trữ phải tự HA; các manifest này không làm HA cho chính cluster Kubernetes.
- Một StorageClass mặc định cấp PVC `ReadWriteOnce` (nên dùng storage trên nhiều node/zone). Dung lượng tối thiểu cho dữ liệu: PostgreSQL 3 × (20 + 5) GiB, Redis 3 × 5 GiB, Kafka 3 × 20 GiB, Elasticsearch 3 × 20 GiB; cộng dung lượng dự phòng và snapshot.
- `kubectl`, Python 3; tài khoản có quyền cài CRD/ClusterRole và tạo tài nguyên trong cluster. Nếu thiếu Helm 3, script dùng `curl` tải Helm 3.22.1, kiểm tra SHA-256 rồi cài vào `~/.local/bin` (có thể đổi bằng `HELM_VERSION` và `HELM_INSTALL_DIR`).
- CPU/RAM trống đủ cho workload và operator; mặc định mỗi Elasticsearch pod yêu cầu 2 GiB RAM, mỗi Kafka pod 2 GiB. Xem requests/limits trong `manifests/` rồi chỉnh theo máy thực tế.
- DNS và registry cho `ghcr.io`, `quay.io`, `docker.elastic.co`, các Helm repository có thể truy cập từ nơi chạy script/cluster.

## StorageClass, PV và PVC cho bốn dịch vụ

Repo dùng [Longhorn 1.13.0](https://longhorn.io/docs/1.13.0/deploy/install/install-with-helm/) để cấp phát động volume `ReadWriteOnce`. Thư mục [`pv/`](pv/) có bốn StorageClass (`ha-postgresql`, `ha-kafka`, `ha-elasticsearch`, `ha-redis`); `ha-postgresql` là class mặc định để đáp ứng preflight. Các manifest trong `manifests/` đã chọn class riêng cho từng dịch vụ. CloudNativePG, Strimzi, ECK và Redis Operator **tự tạo PVC thật**; Longhorn tự tạo PV tương ứng. Các YAML trong [`pvc/`](pvc/) chỉ tạo PVC 1 GiB để kiểm tra bốn class, không phải PVC của workload.

Bốn dịch vụ yêu cầu tổng cộng **210 GiB PVC** (PostgreSQL 75, Redis 15, Kafka 60, Elasticsearch 60 GiB). Bốn class đặt `numberOfReplicas: "3"`, nên cần tối thiểu khoảng **630 GiB dung lượng vật lý** trên ít nhất ba node lưu trữ, chưa tính snapshot, dự phòng và dữ liệu hệ thống. Kiểm tra đĩa trước khi cài; không nên dựa vào dung lượng trống của ổ hệ điều hành. Longhorn cần các gói và cấu hình trên **mọi node lưu trữ**, gồm iSCSI cho data engine mặc định. Làm theo [yêu cầu cài đặt Longhorn](https://longhorn.io/docs/1.13.0/deploy/install/) và kiểm tra với `longhornctl`. Cluster phải có ba worker lưu trữ đủ dung lượng; một control-plane được bỏ taint vẫn không thay thế yêu cầu này cho mục tiêu HA của repo.

### Tạo class

Sau khi chuẩn bị ba worker, gắn/mount đĩa dành cho Longhorn trên mỗi worker tại `/var/lib/longhorn` và cài các gói Longhorn yêu cầu trên từng node, chạy từ nơi có `kubectl` và Helm 3. Thay `WORKER_1`–`WORKER_3` bằng tên thực tế từ `kubectl get nodes`; **không gắn nhãn control-plane**. [Longhorn: tạo đĩa trên node có nhãn](https://longhorn.io/docs/1.13.0/nodes-and-volumes/nodes/default-disk-and-node-config/)

```bash
export KUBE_CONTEXT=kubernetes-admin@kubernetes # thay bằng context của bạn
kubectl --context "$KUBE_CONTEXT" get nodes
kubectl --context "$KUBE_CONTEXT" label node WORKER_1 WORKER_2 WORKER_3 \
  node.longhorn.io/create-default-disk=true
helm repo add longhorn https://charts.longhorn.io --force-update
helm repo update longhorn
helm --kube-context "$KUBE_CONTEXT" upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace --version 1.13.0 \
  -f config/longhorn-values.yaml --wait --timeout 20m
kubectl --context "$KUBE_CONTEXT" -n longhorn-system get pods
kubectl --context "$KUBE_CONTEXT" get csidriver
```

[`config/longhorn-values.yaml`](config/longhorn-values.yaml) chỉ tạo đĩa Longhorn trên node có nhãn và tắt StorageClass mặc định do chart tạo, để repo quản lý các class trong `pv/`. Chỉ tiếp tục khi Longhorn và CSI driver đã sẵn sàng. Nếu cluster đã có class mặc định khác, bỏ dấu mặc định của nó trước khi áp dụng các file bên dưới để tránh hai class mặc định. [Kubernetes: đổi StorageClass mặc định](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/)

```bash
kubectl --context "$KUBE_CONTEXT" apply -f pv/
kubectl --context "$KUBE_CONTEXT" get storageclass
```

Kết quả cần có bốn class với `PROVISIONER=driver.longhorn.io`; `ha-postgresql` có dấu `(default)`. Chỉ tạo StorageClass khi chưa có Longhorn sẽ không cấp phát được PV. Các class dùng `reclaimPolicy: Retain`: xóa PVC không tự xóa dữ liệu/PV; cần thu hồi thủ công khi không còn dùng. [Tham số StorageClass của Longhorn](https://longhorn.io/docs/1.13.0/references/storage-class-parameters/)

### Kiểm tra cấp phát

```bash
kubectl --context "$KUBE_CONTEXT" create namespace storage-check
kubectl --context "$KUBE_CONTEXT" apply -f pvc/
kubectl --context "$KUBE_CONTEXT" -n storage-check get pvc -o wide
kubectl --context "$KUBE_CONTEXT" get pv
```

Đợi cả bốn PVC chuyển sang `Bound`. Nếu PVC `Pending`, xem `kubectl --context "$KUBE_CONTEXT" -n storage-check describe pvc TEN_PVC` và trạng thái pod trong `longhorn-system`. Ghi lại tên PV trước khi dọn PVC thử:

```bash
kubectl --context "$KUBE_CONTEXT" -n storage-check get pvc \
  -o custom-columns=NAME:.metadata.name,PV:.spec.volumeName
kubectl --context "$KUBE_CONTEXT" delete -f pvc/
kubectl --context "$KUBE_CONTEXT" delete namespace storage-check
```

Do `reclaimPolicy: Retain`, các PV thử nghiệm sẽ ở trạng thái `Released`. Xóa volume thử và thu hồi PV theo [quy trình Longhorn](https://longhorn.io/docs/1.13.0/nodes-and-volumes/volumes/delete-volumes/) trước khi sử dụng dung lượng đó cho workload. Sau khi xác nhận bốn class hoạt động, chạy các script cài dịch vụ bên dưới.

| Dịch vụ | StorageClass | Trường trong manifest |
|---|---|---|
| PostgreSQL | `ha-postgresql` | `spec.storage.storageClass` và `spec.walStorage.storageClass` |
| Kafka | `ha-kafka` | `KafkaNodePool.spec.storage.volumes[].class` |
| Elasticsearch | `ha-elasticsearch` | `spec.nodeSets[].volumeClaimTemplates[].spec.storageClassName` |
| Redis | `ha-redis` | `RedisReplication.spec.storage.volumeClaimTemplate.spec.storageClassName`; Sentinel hiện không có PVC |

Các trường PVC theo tài liệu [CloudNativePG](https://cloudnative-pg.io/docs/1.28/cloudnative-pg.v1/), [Strimzi](https://strimzi.io/docs/operators/latest/full/deploying.html), [Elastic ECK](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/volume-claim-templates) và [OpsTree Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator/blob/main/example/v1beta2/password_protected/sentinel.yaml). Đổi class của PVC đã tạo cần quy trình di chuyển dữ liệu riêng.

## Cài từng dịch vụ

```bash
kubectl config get-contexts

# Ví dụ: chỉ cài PostgreSQL
cp secrets/postgresql.example.yaml secrets/postgresql.yaml
chmod 600 secrets/postgresql.yaml
# Sửa 2 mật khẩu CHANGE_ME trong secrets/postgresql.yaml
KUBE_CONTEXT=my-cluster ./scripts/postgresql.sh install
KUBE_CONTEXT=my-cluster ./scripts/postgresql.sh verify
```

Thay `my-cluster` bằng tên context thực tế. Mỗi script chỉ cài operator, Secret và manifest của chính dịch vụ đó:

| Dịch vụ | Secret mẫu → file cần tạo | Cấu hình operator / phiên bản | Manifest | Script |
|---|---|---|---|---|
| PostgreSQL | `postgresql.example.yaml` → `postgresql.yaml` | `config/cnpg-values.yaml`, `config/postgresql.env` | `manifests/postgresql.yaml` | `scripts/postgresql.sh` |
| Redis | `redis.example.yaml` → `redis.yaml` | `config/redis-operator-values.yaml`, `config/redis.env` | `manifests/redis.yaml` | `scripts/redis.sh` |
| Kafka | `kafka.example.yaml` → `kafka.yaml` | `config/strimzi-values.yaml`, `config/kafka.env` | `manifests/kafka.yaml` | `scripts/kafka.sh` |
| Elasticsearch | `elasticsearch.example.yaml` → `elasticsearch.yaml` | `config/eck-values.yaml`, `config/elasticsearch.env` | `manifests/elasticsearch.yaml` | `scripts/elasticsearch.sh` |

Tất cả Secret nằm trong thư mục `secrets/`; mỗi file thật phải thay `CHANGE_ME` và đặt quyền `chmod 600`. Ví dụ cài riêng Redis:

```bash
cp secrets/redis.example.yaml secrets/redis.yaml
chmod 600 secrets/redis.yaml
# Sửa mật khẩu trong secrets/redis.yaml
KUBE_CONTEXT=my-cluster ./scripts/redis.sh install
KUBE_CONTEXT=my-cluster ./scripts/redis.sh verify
```

Kafka và Elasticsearch chạy tương tự với `scripts/kafka.sh` và `scripts/elasticsearch.sh`. Lệnh `verify` chỉ chờ và hiển thị tài nguyên của dịch vụ được chọn.

## Cài cả bốn dịch vụ

Sau khi tạo đủ bốn Secret từ các file `.example.yaml` và thay mật khẩu:

```bash
KUBE_CONTEXT=my-cluster ./scripts/install.sh
KUBE_CONTEXT=my-cluster ./scripts/verify.sh
```

Mỗi script `install` kiểm tra context, node, StorageClass và Secret của dịch vụ; tạo namespace cần thiết, cài operator rồi áp dụng manifest. Script tổng gọi lần lượt bốn script. Có thể chạy lại để áp dụng thay đổi. Script không tự xoá PVC hay Secret. Nếu cluster đã có các CRD/operator này, kiểm tra quyền sở hữu và phiên bản trước khi cài: CRD là tài nguyên dùng chung toàn cluster.

Giữ các file `secrets/*.yaml` chứa mật khẩu ngoài Git. `stringData` của Kubernetes Secret chỉ giúp nhập cấu hình, **không mã hoá dữ liệu lưu trong etcd**. Bật encryption at rest cho etcd, giới hạn RBAC đọc Secret và dùng SOPS/External Secrets/Vault khi đưa cấu hình vào CI/CD. Tránh ghi mật khẩu trong lệnh shell hoặc output CI.

## Địa chỉ nội bộ

| Dịch vụ | Địa chỉ / cách truy cập |
|---|---|
| PostgreSQL ghi | `postgres-rw.data.svc:5432`, database `app`, user `app` |
| PostgreSQL đọc | `postgres-ro.data.svc:5432` |
| Redis | Redis master Service do operator tạo; xem `kubectl -n data get svc`, Sentinel group `mymaster`, cổng `26379` |
| Kafka | `kafka-kafka-bootstrap.data.svc:9093`, TLS + SASL/SCRAM-SHA-512, user `app`; ACL cho topic/group bắt đầu `app-` |
| Elasticsearch | `https://search-es-http.elasticsearch.svc:9200`, user `elastic`, HTTPS với CA do ECK tạo |

Redis client nên dùng Sentinel để tự tìm master sau failover. Đừng cố định IP/pod. Các Service chỉ ở trong cluster; nếu cần truy cập bên ngoài, cấu hình ingress/load balancer và TLS riêng.

## Xác minh và vận hành

```bash
KUBE_CONTEXT=my-cluster ./scripts/postgresql.sh verify  # hoặc redis.sh, kafka.sh, elasticsearch.sh
kubectl -n data get pods -o wide
kubectl -n data get pvc,pdb
kubectl -n data get events --sort-by=.lastTimestamp
```

Kiểm tra từng nhóm có đủ 3 pod Ready ở 3 node khác nhau, mỗi operator có 2 pod trên 2 node khác nhau; PVC đều Bound; PostgreSQL/Kafka có `Ready=True`; Elasticsearch có `health=green`. Thử dừng lần lượt một pod trên môi trường thử nghiệm và xác nhận ứng dụng vẫn đọc/ghi được. Với Redis, xác nhận Sentinel trả đúng master sau khi failover và sau khi pod cũ khởi động lại. [OpsTree đã có báo cáo lỗi về Sentinel giữ IP master cũ](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1781); cần kiểm thử chính phiên bản triển khai trước production.

HA không thay thế backup. Thiết lập PostgreSQL backup/PITR (CloudNativePG), snapshot Elasticsearch, chính sách dữ liệu Kafka và backup Redis theo RPO/RTO riêng. Thử restore định kỳ. Không xoá CRD, namespace hoặc PVC khi chỉ muốn nâng cấp operator. Trước khi đổi phiên bản trong các file `config/*.env`, đọc hướng dẫn nâng cấp CRD của từng operator; riêng Strimzi có bước nâng cấp CRD tách khỏi Helm.

## Tài liệu gốc

- [CloudNativePG Helm chart](https://github.com/cloudnative-pg/charts/tree/main/charts/cloudnative-pg), [bootstrap và Secret](https://cloudnative-pg.io/docs/1.28/bootstrap/)
- [OpsTree Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator), [ví dụ Sentinel có mật khẩu](https://github.com/OT-CONTAINER-KIT/redis-operator/blob/main/example/v1beta2/password_protected/sentinel.yaml)
- [Strimzi triển khai Kafka KRaft và người dùng](https://strimzi.io/docs/operators/latest/deploying.html)
- [Elastic ECK Helm](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/install), [file realm Secret](https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/file-based)


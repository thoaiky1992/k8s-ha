# RedisInsight kết nối Redis Cluster

Thư mục này triển khai một RedisInsight trong namespace `redisinsight` để quản trị Redis Cluster trong [`../redis-cluster`](../redis-cluster/README.md). RedisInsight chạy một replica, lưu database cấu hình và lịch sử Workbench trên PVC. Giao diện được expose qua Service `ClusterIP` và Ingress có ALB **internet-facing**, chỉ cho phép CIDR `27.74.134.118/32` qua annotation `inbound-cidrs`. RedisInsight chưa có xác thực riêng, nên bất kỳ IP nào khác đều không truy cập được.

## Kiến trúc kết nối

```text
Trình duyệt
    │ kubectl port-forward :5540 (hoặc ALB, chỉ IP được phép)
    ▼
RedisInsight Service/Pod (namespace redisinsight)
    │ TLS tới một node seed, cổng 6379
    ▼
Redis Cluster
    │ trả topology (hostname của từng node)
    ▼
RedisInsight định tuyến theo slot tới các master qua TLS
```

Redis Cluster trả về hostname của từng node, nên RedisInsight xác minh chứng chỉ theo hostname khớp SAN của `redis-cluster-tls`. Không tắt xác minh TLS để kết nối được.

## Các file

| File | Vai trò |
| --- | --- |
| `namespace.yaml` | Tạo namespace `redisinsight`. |
| `secret.yaml.example` | Mẫu Secret chứa encryption key của RedisInsight. |
| `pvc.yaml` | PVC 5 GiB lưu SQLite, cấu hình connection và log, dùng StorageClass `redis-cluster-gp3`. |
| `deployment.yaml` | RedisInsight 3.4.1, health probes, security context và ConfigMap CA `redis-cluster-ca`. |
| `service.yaml` | Service `redisinsight:5540` và Ingress ALB internet-facing `redisinsight` (host `aws-redisinsight.thoaiky.com`, giới hạn `inbound-cidrs`). |

RedisInsight nằm trong namespace `redisinsight`, không dùng chung với namespace của Redis Cluster. Kubernetes không cho Pod mount Secret từ namespace khác, nên CA công khai được copy vào ConfigMap `redis-cluster-ca` trong namespace này. Không copy `tls.key`, và Deployment không mount `tls.key` hay đọc trực tiếp Secret `redis-cluster-auth`.

## Điều kiện

- Cụm trong [`../redis-cluster/README.md`](../redis-cluster/README.md) đã Ready.
- Có StorageClass `redis-cluster-gp3`, Secret `redis-cluster-tls` và `redis-cluster-auth` trong namespace `redis-cluster`.
- Máy triển khai có `kubectl`, `openssl` và context trỏ đúng cluster.

## Cấu hình kubeconfig

Chạy lệnh sau để thêm context của cluster EKS vào kubeconfig hiện tại trước khi kiểm tra và cài đặt:

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
```

Kiểm tra trước khi cài:

```bash
kubectl config get-contexts

export KUBE_CONTEXT="$(kubectl config current-context)"

kubectl --context "$KUBE_CONTEXT" -n redis-cluster get \
  rediscluster/redis-cluster

kubectl --context "$KUBE_CONTEXT" -n redis-cluster get \
  secret/redis-cluster-tls secret/redis-cluster-auth

kubectl --context "$KUBE_CONTEXT" get storageclass redis-cluster-gp3
```

## Tạo encryption key

RedisInsight lưu mật khẩu Redis trong SQLite trên PVC. `RI_ENCRYPTION_KEY` mã hóa dữ liệu nhạy cảm này và phải giữ nguyên khi Pod được tạo lại hoặc PVC được chuyển sang cluster khác.

```bash
cp redisinsight/secret.yaml.example redisinsight/secret.yaml
chmod 600 redisinsight/secret.yaml
openssl rand -base64 48
${EDITOR:-vi} redisinsight/secret.yaml
```

Thay `CHANGE_ME_WITH_OUTPUT_OF_OPENSSL_RAND_BASE64_48` bằng kết quả `openssl rand`. Không commit `secret.yaml`; file này đã được `.gitignore` bỏ qua. Nếu từng commit file này, xóa khỏi index bằng `git rm --cached redisinsight/secret.yaml` và rotate key. Lưu một bản encryption key trong secret manager vì mất key sẽ làm RedisInsight không giải mã được mật khẩu đã lưu.

## Triển khai

Chạy từ root repository:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/namespace.yaml

# CA công khai của Redis Cluster, copy từ Secret redis-cluster-tls. Không copy tls.key.
kubectl --context "$KUBE_CONTEXT" -n redis-cluster get secret redis-cluster-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/redis-cluster-ca.crt
test -s /tmp/redis-cluster-ca.crt

kubectl --context "$KUBE_CONTEXT" -n redisinsight create configmap redis-cluster-ca \
  --from-file=ca.crt=/tmp/redis-cluster-ca.crt \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -

kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/pvc.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/deployment.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/service.yaml

kubectl --context "$KUBE_CONTEXT" -n redisinsight rollout status \
  deployment/redisinsight --timeout=10m

kubectl --context "$KUBE_CONTEXT" -n redisinsight get pod,pvc,service \
  -l app=redisinsight
```

Deployment dùng strategy `Recreate` vì PVC là `ReadWriteOnce` và RedisInsight chỉ chạy một replica. Dữ liệu ứng dụng được lưu tại `/data`; CA công khai được mount tại `/redis-tls/ca.crt` để kiểm tra/troubleshoot trong Pod.

Chờ ALB được tạo rồi mới apply DNS, vì `terraform/02.dns-records/redisinsight.tf` tìm ALB theo tag `ingress.k8s.aws/stack = redisinsight/redisinsight`:

```bash
kubectl --context "$KUBE_CONTEXT" -n redisinsight get ingress redisinsight \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

terraform -chdir=terraform/02.dns-records plan -var-file=terraform.tfvars

terraform -chdir=terraform/02.dns-records apply -var-file=terraform.tfvars
```

Đổi `scheme` của Ingress từ `internet-facing` sang `internal` cần xóa và tạo lại Ingress, vì AWS Load Balancer Controller không đổi scheme của ALB tại chỗ.

## Mở RedisInsight

Ingress tạo ALB **internet-facing** nhưng security group chỉ mở cổng 80/443 cho `27.74.134.118/32`. Đổi danh sách IP được phép bằng annotation `alb.ingress.kubernetes.io/inbound-cidrs` trong `service.yaml`. RedisInsight chưa có xác thực, nên nếu cần mở cho IP khác thì nên thêm OIDC (`auth-type`) trước.

Nếu không truy cập được từ IP trên, mở tunnel tới Service:

```bash
kubectl --context "$KUBE_CONTEXT" -n redisinsight port-forward \
  service/redisinsight 5540:5540
```

Truy cập [http://localhost:5540](http://localhost:5540). Giữ terminal port-forward đang chạy.

## Kết nối Redis Cluster

Các biến môi trường `RI_REDIS_*` chỉ preconfigure kết nối Redis thông thường, không có kết nối cluster. Vì vậy thêm connection trong giao diện.

### 1. Lấy mật khẩu và CA về máy quản trị

```bash
export REDIS_PASSWORD="$(kubectl --context "$KUBE_CONTEXT" -n redis-cluster \
  get secret redis-cluster-auth \
  -o jsonpath='{.data.redis-password}' | base64 --decode)"

kubectl --context "$KUBE_CONTEXT" -n redis-cluster \
  get secret redis-cluster-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/redis-cluster-ca.crt
test -s /tmp/redis-cluster-ca.crt
```

Không nhập hoặc upload `tls.key`; cấu hình hiện tại dùng `tls-auth-clients no`, nên RedisInsight chỉ cần CA để xác minh server và mật khẩu để xác thực.

### 2. Nhập connection trong giao diện

Chọn **Add Redis database** và chọn loại kết nối **Cluster**, sau đó nhập:

| Trường | Giá trị |
| --- | --- |
| Database alias | `redis-cluster-ha` |
| Host | `redis-cluster-leader.redis-cluster.svc.cluster.local` |
| Port | `6379` |
| Username | `default` |
| Password | Giá trị trong biến `REDIS_PASSWORD` ở bước trên. |
| TLS | Bật và xác minh server certificate. |
| CA certificate | Upload `/tmp/redis-cluster-ca.crt`. |
| Client certificate/key | Để trống. |

Tên trường có thể thay đổi nhẹ giữa các phiên bản RedisInsight. Điều quan trọng là chọn loại Cluster, dùng cổng `6379`, bật TLS, xác minh CA và dùng mật khẩu của `redis-cluster-auth`.

Sau khi lưu, mở Workbench và chạy:

```redis
CLUSTER INFO
CLUSTER NODES
```

`CLUSTER INFO` phải có `cluster_state:ok` và `cluster_known_nodes:6`. `CLUSTER NODES` phải liệt kê 3 master có slot và 3 replica.

Sau khi nhập mật khẩu xong:

```bash
unset REDIS_PASSWORD
rm -f /tmp/redis-cluster-ca.crt
```

## Kiểm tra failover

Trước khi thử trên production, tạo một key thử trong Workbench:

```redis
SET redisinsight:failover-test before
GET redisinsight:failover-test
```

Thực hiện failover theo quy trình vận hành của cluster (ví dụ xóa một Pod master ở môi trường thử), chờ `CLUSTER INFO` báo `cluster_state:ok` trở lại, sau đó chạy:

```redis
SET redisinsight:failover-test after
GET redisinsight:failover-test
CLUSTER NODES
```

Không xóa Pod master để thử khi chưa xác nhận backup S3 gần nhất và chưa có maintenance window.

## Troubleshooting

Xem trạng thái và log:

```bash
kubectl --context "$KUBE_CONTEXT" -n redisinsight describe deployment redisinsight
kubectl --context "$KUBE_CONTEXT" -n redisinsight logs deployment/redisinsight -f
kubectl --context "$KUBE_CONTEXT" -n redisinsight exec deployment/redisinsight -- \
  test -r /redis-tls/ca.crt
```

- `ENOTFOUND`: hostname node trả về từ Redis Cluster không phân giải được trong cluster; kiểm tra RedisInsight đang chạy trong cluster và `cluster-preferred-endpoint-type hostname` đã bật.
- `certificate verify failed`: upload đúng `ca.crt` của `redis-cluster-tls`, bật TLS và không dùng IP do IP không nằm trong SAN. Nếu CA đã xoay vòng, tạo lại ConfigMap `redis-cluster-ca` rồi restart Deployment.
- `WRONGPASS` hoặc `NOAUTH`: kiểm tra password từ Secret `redis-cluster-auth`.
- Sau khi đổi `RI_ENCRYPTION_KEY`, connection cũ không giải mã được: khôi phục key cũ hoặc xóa/tạo lại connection.
- PVC Pending: kiểm tra EBS CSI, StorageClass `redis-cluster-gp3` và node/AZ.

Tài liệu tham khảo: [RedisInsight trên Kubernetes](https://redis.io/docs/latest/operate/redisinsight/install/install-on-k8s/), [cấu hình RedisInsight](https://redis.io/docs/latest/operate/redisinsight/configuration/) và [Redis Cluster](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/).

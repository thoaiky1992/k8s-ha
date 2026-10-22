# RedisInsight kết nối Redis Sentinel

Thư mục này triển khai một RedisInsight trong namespace `redis-sentinel` để quản trị cụm Redis HA. RedisInsight chạy một replica, lưu database cấu hình và lịch sử Workbench trên PVC. Giao diện được expose qua Service `ClusterIP` và Ingress có ALB **internet-facing**, chỉ cho phép CIDR `27.74.134.118/32` qua annotation `inbound-cidrs`. RedisInsight chưa có xác thực riêng, nên bất kỳ IP nào khác đều không truy cập được.

## Kiến trúc kết nối

```text
Trình duyệt
    │ kubectl port-forward :5540
    ▼
RedisInsight Service/Pod
    │ hỏi master group "mymaster" qua TLS, cổng 26379
    ▼
Redis Sentinel
    │ trả hostname primary hiện tại
    ▼
Redis primary qua TLS, cổng 6379
```

RedisInsight không gửi lệnh dữ liệu tới cổng Sentinel. Nó hỏi Sentinel địa chỉ primary rồi kết nối trực tiếp tới Redis primary. Khi failover xảy ra, connection kiểu Sentinel có thể khám phá primary mới.

## Các file

| File | Vai trò |
| --- | --- |
| `secret.yaml.example` | Mẫu Secret chứa encryption key của RedisInsight. |
| `pvc.yaml` | PVC 5 GiB lưu SQLite, cấu hình connection và log. |
| `deployment.yaml` | RedisInsight 3.4.1, health probes và security context. |
| `service.yaml` | Service `redisinsight:5540` và Ingress ALB internet-facing `redisinsight` (host `aws-redisinsight.thoaiky.com`, giới hạn `inbound-cidrs`). |

RedisInsight được đặt cùng namespace `redis-sentinel` để có thể project riêng khóa công khai `ca.crt` từ Secret `redis-sentinel-tls`. Deployment không mount `tls.key` và không đọc trực tiếp mật khẩu `redis-sentinel-auth`.

## Điều kiện

- Cụm trong [`../redis-sentinel/README.md`](../redis-sentinel/README.md) đã Ready.
- Có StorageClass `redis-sentinel-gp3` và Secret `redis-sentinel-tls`, `redis-sentinel-auth` trong namespace `redis-sentinel`.
- Máy triển khai có `kubectl`, `openssl` và context trỏ đúng cluster.

Kiểm tra trước khi cài:

```bash
kubectl config get-contexts

export KUBE_CONTEXT="$(kubectl config current-context)"

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get \
  redisreplication/redis-sentinel redissentinel/redis-sentinel

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get \
  secret/redis-sentinel-tls secret/redis-sentinel-auth
  
kubectl --context "$KUBE_CONTEXT" get storageclass redis-sentinel-gp3
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
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/pvc.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/deployment.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/service.yaml

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel rollout status \
  deployment/redisinsight --timeout=10m
  
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get pod,pvc,service \
  -l app=redisinsight
```

Deployment dùng strategy `Recreate` vì PVC là `ReadWriteOnce` và RedisInsight chỉ chạy một replica. Dữ liệu ứng dụng được lưu tại `/data`; CA công khai được mount tại `/redis-tls/ca.crt` để kiểm tra/troubleshoot trong Pod.

Chờ ALB được tạo rồi mới apply DNS, vì `terraform/02.dns-records/redisinsight.tf` tìm ALB theo tag `ingress.k8s.aws/stack = redis-sentinel/redisinsight`:

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get ingress redisinsight \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

terraform -chdir=terraform/02.dns-records plan -var-file=terraform.tfvars
terraform -chdir=terraform/02.dns-records apply -var-file=terraform.tfvars
```

Đổi `scheme` của Ingress từ `internet-facing` sang `internal` cần xóa và tạo lại Ingress, vì AWS Load Balancer Controller không đổi scheme của ALB tại chỗ.

## Mở RedisInsight

Ingress tạo ALB **internet-facing** nhưng security group chỉ mở cổng 80/443 cho `27.74.134.118/32`. Đổi danh sách IP được phép bằng annotation `alb.ingress.kubernetes.io/inbound-cidrs` trong `service.yaml`. RedisInsight chưa có xác thực, nên nếu cần mở cho IP khác thì nên thêm OIDC (`auth-type`) trước.

Nếu không truy cập được từ IP trên, mở tunnel tới Service:

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel port-forward \
  service/redisinsight 5540:5540
```

Truy cập [http://localhost:5540](http://localhost:5540). Giữ terminal port-forward đang chạy.

## Kết nối Redis Sentinel

RedisInsight hỗ trợ Sentinel qua form kết nối trong UI, nhưng các biến môi trường `RI_REDIS_*` chỉ preconfigure kết nối Redis thông thường và không có trường khai báo loại Sentinel. Vì vậy không đặt `RI_REDIS_HOST=redis-sentinel-sentinel...`: cách đó có thể bị hiểu là một Redis database ở cổng Sentinel thay vì connection Sentinel hoàn chỉnh.

### 1. Lấy mật khẩu và CA về máy quản trị

```bash
export REDIS_PASSWORD="$(kubectl --context "$KUBE_CONTEXT" -n redis-sentinel \
  get secret redis-sentinel-auth \
  -o jsonpath='{.data.redis-password}' | base64 --decode)"

kubectl --context "$KUBE_CONTEXT" -n redis-sentinel \
  get secret redis-sentinel-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/redis-sentinel-ca.crt
test -s /tmp/redis-sentinel-ca.crt
```

Không nhập hoặc upload `tls.key`; cấu hình hiện tại dùng `tls-auth-clients no`, nên RedisInsight chỉ cần CA để xác minh server và mật khẩu để xác thực.

### 2. Nhập connection trong giao diện

Chọn **Add Redis database** và chọn loại kết nối **Sentinel**, sau đó nhập:

| Trường | Giá trị |
| --- | --- |
| Database alias | `redis-sentinel-ha` |
| Sentinel host | `redis-sentinel-sentinel.redis-sentinel.svc.cluster.local` |
| Sentinel port | `26379` |
| Master group name | `mymaster` |
| Redis username | `default` |
| Redis password | Giá trị trong biến `REDIS_PASSWORD` ở bước trên. |
| Sentinel username | `default` nếu giao diện yêu cầu. |
| Sentinel password | Cùng mật khẩu Redis vì manifest dùng chung `redis-sentinel-auth`. |
| TLS | Bật cho cả Sentinel và Redis data node. |
| CA certificate | Upload `/tmp/redis-sentinel-ca.crt`. |
| Client certificate/key | Để trống. |

Tên trường có thể thay đổi nhẹ giữa các phiên bản RedisInsight. Điều quan trọng là chọn connection type Sentinel, master group `mymaster`, dùng cổng `26379`, bật TLS/xác minh CA và dùng cùng mật khẩu cho Sentinel lẫn Redis.

Sau khi lưu, mở Browser hoặc Workbench và chạy:

```redis
PING
INFO replication
```

`PING` phải trả `PONG`; `INFO replication` trên connection ghi phải hiển thị `role:master`.

Sau khi nhập mật khẩu xong:

```bash
unset REDIS_PASSWORD
rm -f /tmp/redis-sentinel-ca.crt
```

## Kiểm tra failover

Trước khi thử trên production, tạo một key thử trong Workbench:

```redis
SET redisinsight:failover-test before
GET redisinsight:failover-test
```

Thực hiện failover theo quy trình vận hành của cluster, chờ Sentinel công bố primary mới, sau đó reconnect connection trong RedisInsight và chạy:

```redis
SET redisinsight:failover-test after
GET redisinsight:failover-test
INFO replication
```

Không xóa Pod primary để thử khi chưa xác nhận backup S3 gần nhất và chưa có maintenance window.

## Troubleshooting

Xem trạng thái và log:

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel describe deployment redisinsight
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel logs deployment/redisinsight -f
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel exec deployment/redisinsight -- \
  test -r /redis-tls/ca.crt
```

- `ENOTFOUND`: kiểm tra Sentinel trả hostname có thể phân giải trong cluster và RedisInsight đang chạy trong namespace `redis-sentinel`.
- `certificate verify failed`: upload đúng `ca.crt`, bật TLS cho cả Sentinel/Redis và không dùng IP do IP không nằm trong SAN.
- `WRONGPASS` hoặc `NOAUTH`: kiểm tra password từ Secret `redis-sentinel-auth` cho cả hai phần Redis và Sentinel.
- Sau khi đổi `RI_ENCRYPTION_KEY`, connection cũ không giải mã được: khôi phục key cũ hoặc xóa/tạo lại connection.
- PVC Pending: kiểm tra EBS CSI, StorageClass `redis-sentinel-gp3` và node/AZ.

Tài liệu tham khảo: [RedisInsight trên Kubernetes](https://redis.io/docs/latest/operate/redisinsight/install/install-on-k8s/), [cấu hình RedisInsight](https://redis.io/docs/latest/operate/redisinsight/configuration/) và [Redis Sentinel](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/).

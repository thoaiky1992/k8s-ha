# Node.js kết nối Elasticsearch và Redis qua TLS

Thư mục này chứa ứng dụng Node.js mẫu, Dockerfile, Deployment và hướng dẫn cấu hình TLS. Ứng dụng xác minh chứng chỉ máy chủ bằng CA riêng của từng dịch vụ. Redis dùng Sentinel để tìm primary sau failover; kết nối tới Sentinel **và** Redis đều dùng TLS.

| Tệp | Mục đích |
| --- | --- |
| `server.js`, `package.json`, `Dockerfile` | Ứng dụng HTTP và ảnh container. |
| `namespace.yaml`, `deployment.yaml` | Namespace và Deployment Kubernetes. |
| `credentials.env.example` | Mẫu biến môi trường dùng để tạo Secret. |

## Điều kiện trước khi chạy

- Elasticsearch trong `elasticsearch/elasticsearch.yaml` đã sẵn sàng; ECK tạo Secret `search-es-http-certs-public` với `ca.crt` ở namespace `elasticsearch`.
- Terraform `terraform/01.kubernetes/10.cert-manager.tf` đã cài cert-manager. Redis replication và Sentinel trong `redis-sentinel/redis-sentinel-replication.yaml`, `redis-sentinel/redis-sentinel.yaml` đã sẵn sàng; `redis-sentinel/certificate.yaml` cấp CA trong Secret `redis-sentinel-ca` với `tls.crt` ở namespace `redis-sentinel`.
- Có tài khoản Elasticsearch được cấp quyền phù hợp cho ứng dụng. Ví dụ có thể dùng tài khoản `elastic` để thử kết nối, sau đó thay bằng tài khoản có quyền tối thiểu. Mật khẩu Redis lấy từ Secret `redis-sentinel-auth` trong namespace `redis-sentinel`.
- Máy triển khai có `kubectl`, Docker và quyền push image tới registry mà cluster có thể kéo.

Các lệnh dưới đây chạy từ **gốc repository**. Đặt context Kubernetes trước để tránh ghi nhầm cluster:

```bash
export KUBE_CONTEXT=<ten-context-cua-ban>
kubectl --context "$KUBE_CONTEXT" apply -f app/namespace.yaml
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get svc
```

Kiểm tra tên Service Sentinel và cổng `26379`. `deployment.yaml` đang dùng `redis-sentinel-sentinel.redis-sentinel.svc`; OT Redis Operator thêm hậu tố `-sentinel` vào tên `RedisSentinel` CR. Nếu tên thực tế khác, sửa `REDIS_SENTINEL_HOST`. Redis Sentinel phải trả hostname khớp DNS SAN của chứng chỉ Redis, không phải IP. Có thể kiểm tra bằng lệnh `redis-cli` trong [hướng dẫn Redis Sentinel](../redis-sentinel/README.md).

## Tạo CA và Secret cho ứng dụng

Kubernetes không cho Pod mount Secret từ namespace khác. Sao chép **chỉ chứng chỉ CA công khai**, không sao chép khóa riêng `tls.key`, vào ConfigMap `backend-ca` trong namespace `app`:

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get secret search-es-http-certs-public \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/elasticsearch-ca.crt
kubectl --context "$KUBE_CONTEXT" -n redis-sentinel get secret redis-sentinel-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/redis-sentinel-ca.crt
test -s /tmp/elasticsearch-ca.crt && test -s /tmp/redis-sentinel-ca.crt

kubectl --context "$KUBE_CONTEXT" -n app create configmap backend-ca \
  --from-file=elasticsearch-ca.crt=/tmp/elasticsearch-ca.crt \
  --from-file=redis-sentinel-ca.crt=/tmp/redis-sentinel-ca.crt \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
```

Tạo Secret chứa thông tin đăng nhập trong namespace `app`. Không commit tệp `app/credentials.env` vì tệp này chứa mật khẩu; nó đã được thêm vào `.gitignore` của thư mục:

```bash
cp app/credentials.env.example app/credentials.env
# Sửa app/credentials.env: ELASTICSEARCH_USERNAME, ELASTICSEARCH_PASSWORD, REDIS_PASSWORD.
kubectl --context "$KUBE_CONTEXT" -n app create secret generic backend-credentials \
  --from-env-file=app/credentials.env \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
```

`REDIS_PASSWORD` phải trùng khóa `redis-password` của Secret `redis-sentinel-auth`. Nếu đổi mật khẩu hay CA, cập nhật Secret/ConfigMap tương ứng và khởi động lại Deployment để ứng dụng đọc lại cấu hình. Không dùng `rejectUnauthorized: false` hoặc bỏ qua xác minh hostname.

## Build và triển khai

```bash
docker build -t ghcr.io/<org>/node-api:1.0.0 app
docker push ghcr.io/<org>/node-api:1.0.0
```

Sửa `image` trong `app/deployment.yaml` thành image đã push. Nếu registry riêng tư, tạo `imagePullSecret` trong namespace `app` và gắn vào Pod. Sau đó:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f app/deployment.yaml
kubectl --context "$KUBE_CONTEXT" -n app rollout status deployment/node-api
kubectl --context "$KUBE_CONTEXT" -n app logs deployment/node-api --all-pods=true --prefix=true -f
```

Để kiểm tra HTTP từ máy cục bộ:

```bash
kubectl --context "$KUBE_CONTEXT" -n app port-forward deployment/node-api 3000:3000
# Terminal khác:
curl -i http://localhost:3000/healthz
curl -i http://localhost:3000/readyz
```

`/healthz` trả 200 khi tiến trình HTTP còn chạy. `/readyz` chỉ trả 200 khi cả Elasticsearch `ping()` và Redis `PING` thành công; nếu một trong hai lỗi, trả 503 kèm trạng thái từng dịch vụ. Readiness probe dùng `/readyz`, liveness probe dùng `/healthz`.

Log có tiền tố riêng để dễ lọc:

```text
[elasticsearch] connected over TLS: https://search-es-http.elasticsearch.svc:9200
[redis] connected over TLS via Sentinel redis-sentinel-sentinel.redis-sentinel.svc:26379 (master: mymaster)
[elasticsearch] TLS connection failed: <chi-tiet-loi>
[redis] TLS connection failed: <chi-tiet-loi>
```

Ứng dụng kiểm tra lại Elasticsearch và Redis mỗi 15 giây. Redis client cũng ghi lỗi kết nối và sự kiện reconnect, rồi tìm lại primary qua Sentinel. Khi lỗi khởi động do thiếu biến môi trường hoặc không đọc được CA, tiến trình ghi log và thoát để Kubernetes báo lỗi rõ ràng.

## Gia hạn chứng chỉ

Khi ECK thay CA của Elasticsearch hoặc CA `redis-sentinel-ca` được xoay vòng, tạo lại ConfigMap `backend-ca` từ CA mới rồi chạy `kubectl --context "$KUBE_CONTEXT" -n app rollout restart deployment/node-api`. Khi chỉ chứng chỉ máy chủ được gia hạn dưới cùng CA, client vẫn tin cậy CA hiện tại; xem thêm quy trình khởi động lại Redis/Sentinel trong [hướng dẫn Redis Sentinel](../redis-sentinel/README.md).

Tham khảo: [Elastic JavaScript client TLS](https://www.elastic.co/docs/reference/elasticsearch/clients/javascript/connecting), [node-redis Sentinel](https://github.com/redis/node-redis/blob/master/docs/sentinel.md), [node-redis TLS](https://github.com/redis/node-redis/blob/master/docs/client-configuration.md).

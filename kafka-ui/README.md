# Kafka UI cho Strimzi Kafka

Thư mục này triển khai Kafbat UI 1.5.0 trong namespace `kafka`. UI kết nối tới
`kafka-cluster` qua TLS hai chiều bằng `KafkaUser` riêng, chạy ở chế độ read-only
và yêu cầu đăng nhập local. Ingress dùng ALB internet-facing nhưng chỉ nhận CIDR
`125.235.126.15/32`; TLS kết thúc ở ALB bằng certificate ACM khớp host
`aws-kafka-ui.thoaiky.com`.

## Điều kiện

- Kafka `kafka-cluster`, Kafka Connect và Strimzi operator đã Ready.
- Node group `workload=kafka-connect` có node Ready.
- AWS Load Balancer Controller đã chạy.
- Terraform `01.kubernetes` đã tạo hosted zone và ACM certificate cho
  `aws-kafka-ui.thoaiky.com`.

## Triển khai

Chạy từ root repository và luôn đặt context rõ ràng:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"

kubectl --context "$KUBE_CONTEXT" apply -f kafka-ui/kafka-user.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka wait kafkauser/kafka-ui \
  --for=condition=Ready --timeout=5m

cp kafka-ui/secret.yaml.example kafka-ui/secret.yaml
openssl rand -base64 36
${EDITOR:-vi} kafka-ui/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-ui/secret.yaml

kubectl --context "$KUBE_CONTEXT" apply -f kafka-ui/deployment.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-ui/service.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka rollout status \
  deployment/kafka-ui --timeout=10m
```

`secret.yaml` đã được ignore. Lưu password trong secret manager và không commit
file này. ALB certificate được controller tìm theo hostname trong Ingress, nên
không cần chép ARN vào manifest.

## Kiểm tra

```bash
kubectl --context "$KUBE_CONTEXT" -n kafka get pod,service,ingress -l app=kafka-ui
kubectl --context "$KUBE_CONTEXT" -n kafka logs deployment/kafka-ui

# Truy cập nội bộ khi DNS/ALB chưa sẵn sàng.
kubectl --context "$KUBE_CONTEXT" -n kafka port-forward service/kafka-ui 8080:8080
```

Mở `http://localhost:8080` khi port-forward hoặc
`https://aws-kafka-ui.thoaiky.com` sau khi tạo bản ghi DNS trỏ tới ALB.

## Quyền

`KafkaUser kafka-ui` chỉ có `Describe`/`Read`; `KAFKA_CLUSTERS_0_READONLY=true`
ẩn các thao tác ghi trong UI. Kafka Connect REST API hiện chỉ truy cập được từ
trong cluster và UI cũng chạy read-only. Đổi CIDR trong `service.yaml` nếu IP
quản trị thay đổi.

## Gỡ cài đặt theo thứ tự ngược

Gỡ Kafka UI trước Kafka cluster. `KafkaUser` phải được xóa khi Strimzi User Operator vẫn đang chạy.

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"

# Xóa Ingress trước và chờ AWS Load Balancer Controller dọn ALB.
kubectl --context "$KUBE_CONTEXT" delete -f kafka-ui/service.yaml \
  --ignore-not-found=true
kubectl --context "$KUBE_CONTEXT" -n kafka wait --for=delete \
  ingress/kafka-ui --timeout=10m || true

kubectl --context "$KUBE_CONTEXT" delete -f kafka-ui/deployment.yaml \
  --ignore-not-found=true
kubectl --context "$KUBE_CONTEXT" -n kafka delete \
  secret/kafka-ui-auth --ignore-not-found=true

kubectl --context "$KUBE_CONTEXT" delete -f kafka-ui/kafka-user.yaml \
  --ignore-not-found=true --wait=true
```

Secret mTLS `kafka-ui` do Strimzi tạo sẽ được User Operator dọn cùng `KafkaUser`. Không xóa namespace `kafka` trong bước này vì namespace còn chứa Kafka, Kafka Connect và backup jobs. Nếu DNS được quản lý bằng `terraform/02.dns-records`, xóa record Kafka UI bằng Terraform sau khi Ingress/ALB đã biến mất.

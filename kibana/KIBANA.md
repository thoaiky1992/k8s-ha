# Kibana trên ECK

`deployment.yaml` khai báo Kibana CR. ECK tạo Deployment 2 replica và tự cấu hình kết nối TLS cùng thông tin xác thực tới Elasticsearch `search` trong namespace `elasticsearch`. Phiên bản Kibana phải khớp phiên bản Elasticsearch (`9.5.5`).

`service.yaml` tạo AWS NLB public theo mẫu ở `terraform/5-example/2-service.yaml`. NLB chuyển tiếp TCP 443 tới HTTPS 5601 của Kibana; ECK vẫn giữ Service `kibana-kb-http` nội bộ.

```bash
export KUBE_CONTEXT="<ten-kubectl-context>"
kubectl --context "$KUBE_CONTEXT" get elasticsearch -n elasticsearch search
kubectl --context "$KUBE_CONTEXT" apply -f kibana/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kibana/deployment.yaml
kubectl --context "$KUBE_CONTEXT" -n kibana wait --for=jsonpath='{.status.health}'=green kibana/kibana --timeout=15m
kubectl --context "$KUBE_CONTEXT" -n kibana get kibana kibana
kubectl --context "$KUBE_CONTEXT" -n kibana get deployment kibana-kb
kubectl --context "$KUBE_CONTEXT" -n kibana get pods -l kibana.k8s.elastic.co/name=kibana -o wide

# Chỉ tạo NLB public sau khi cấu hình chứng chỉ HTTPS cho tên miền truy cập.
kubectl --context "$KUBE_CONTEXT" apply -f kibana/service.yaml
kubectl --context "$KUBE_CONTEXT" -n kibana get service kibana-public
kubectl --context "$KUBE_CONTEXT" -n kibana get endpointslice -l kubernetes.io/service-name=kibana-public
```

Mở Kibana bằng `https://<EXTERNAL-IP>` (DNS do lệnh `get service` trả về). Service chỉ nghe cổng 443; gõ tên DNS không có `https://` có thể khiến trình duyệt thử HTTP cổng 80. Ví dụ:

```bash
KIBANA_HOST=$(kubectl --context "$KUBE_CONTEXT" -n kibana get service kibana-public \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "https://${KIBANA_HOST}/"
curl -vkI "https://${KIBANA_HOST}/"  # Chỉ bỏ qua kiểm tra chứng chỉ để chẩn đoán.
```

Nếu HTTPS vẫn không mở được, kiểm tra Pod và EndpointSlice trước, sau đó kiểm tra trạng thái `healthy` của target group trên AWS. Có thể thử đường nội bộ để phân biệt lỗi Kibana với lỗi NLB:

```bash
kubectl --context "$KUBE_CONTEXT" -n kibana get pods -l kibana.k8s.elastic.co/name=kibana -o wide
kubectl --context "$KUBE_CONTEXT" -n kibana get endpointslice -l kubernetes.io/service-name=kibana-public -o yaml
kubectl --context "$KUBE_CONTEXT" -n kibana port-forward service/kibana-kb-http 5601:5601
# Chạy ở terminal khác: curl -vkI https://localhost:5601/
```

ECK cấp chứng chỉ tự ký cho Kibana theo mặc định. Trước khi dùng NLB public trong production, cấu hình tên miền và chứng chỉ được tin cậy cho Kibana bằng `spec.http.tls.certificate.secretName`. NLB ở đây chỉ chuyển tiếp TLS nên trình duyệt kiểm tra chứng chỉ của Kibana. Cân nhắc giới hạn nguồn truy cập bằng `spec.loadBalancerSourceRanges` trong `service.yaml` theo mạng của tổ chức.

Nếu Kibana không lên, kiểm tra `kubectl -n kibana describe kibana kibana`, `kubectl -n kibana describe pod -l kibana.k8s.elastic.co/name=kibana` và log của operator trong `elastic-system`. Cả hai namespace phải được cùng một ECK operator quản lý.

# Kibana trên ECK

`deployment.yaml` khai báo Kibana CR. ECK tạo Deployment 2 replica và tự cấu hình kết nối TLS cùng thông tin xác thực tới Elasticsearch `search` trong namespace `elasticsearch`. Phiên bản Kibana phải khớp phiên bản Elasticsearch (`9.5.5`).

## Kibana kết nối Elasticsearch qua TLS

`spec.elasticsearchRef` trong `deployment.yaml` trỏ tới `search` ở namespace `elasticsearch`. Khi cùng một ECK operator quản lý cả hai namespace, ECK tự cấu hình URL HTTPS `search-es-http.elasticsearch.svc:9200`, CA tin cậy và thông tin xác thực cho Kibana; ECK sao chép Secret cần thiết sang namespace `kibana`. Không cần tạo thêm certificate bằng cert-manager, mount CA thủ công hay đặt `elasticsearch.hosts`/mật khẩu trong Kibana CR. [Tài liệu ECK về Kibana kết nối Elasticsearch](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s/k8s-kibana-es).

Kiểm tra association và log khi Kibana khởi động:

```bash
export KUBE_CONTEXT="<ten-kubectl-context>"
kubectl --context "$KUBE_CONTEXT" -n kibana get kibana kibana \
  -o jsonpath='{.status.associationStatus}{"\n"}{.status.health}{"\n"}'
kubectl --context "$KUBE_CONTEXT" -n kibana describe kibana kibana
kubectl --context "$KUBE_CONTEXT" -n kibana logs deployment/kibana-kb -c kibana --tail=100
```

Association cần ở trạng thái `Established`, Kibana health là `green`. Nếu association vẫn `Pending`, kiểm tra ECK có theo dõi cả hai namespace, Secret/chứng chỉ HTTP của Elasticsearch và các sự kiện trong `describe`. Nếu association đã `Established` nhưng Kibana chưa `green`, xem log Kibana để tìm lỗi TLS hoặc xác thực.

`service.yaml` tạo AWS ALB internet-facing qua AWS Load Balancer Controller. ALB nhận HTTP trên cổng 80 và chuyển tiếp HTTPS tới Service `kibana-kb-http` của ECK. Vì chưa cấu hình ACM certificate, kết nối từ trình duyệt tới ALB chưa được mã hóa; chỉ dùng cho thử nghiệm, không gửi thông tin đăng nhập qua mạng công cộng. Production cần thêm ACM certificate và HTTPS listener.

```bash
export KUBE_CONTEXT="<ten-kubectl-context>"

kubectl --context "$KUBE_CONTEXT" get elasticsearch -n elasticsearch search

kubectl --context "$KUBE_CONTEXT" apply -f kibana/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kibana/deployment.yaml
kubectl --context "$KUBE_CONTEXT" -n kibana wait --for=jsonpath='{.status.health}'=green kibana/kibana --timeout=15m

kubectl --context "$KUBE_CONTEXT" -n kibana get kibana kibana
kubectl --context "$KUBE_CONTEXT" -n kibana get deployment kibana-kb
kubectl --context "$KUBE_CONTEXT" -n kibana get pods -l kibana.k8s.elastic.co/name=kibana -o wide

# Tạo ALB cho Kibana.
# Cập nhật alb.ingress.kubernetes.io/certificate-arn trong kibana/service.yaml bằng certificate_arn từ output của module terraform/01.kubernetes.
kubectl --context "$KUBE_CONTEXT" apply -f kibana/service.yaml
kubectl --context "$KUBE_CONTEXT" -n kibana get ingress kibana -o wide
kubectl --context "$KUBE_CONTEXT" -n kibana get endpointslice -l kubernetes.io/service-name=kibana-kb-http
```

Khi ALB được tạo, mở Kibana bằng hostname do Ingress trả về:

```bash
ALB_HOST=$(kubectl --context "$KUBE_CONTEXT" -n kibana get ingress kibana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://${ALB_HOST}/"
curl -I "http://${ALB_HOST}/"
```

Nếu ALB chưa có hostname, kiểm tra Pod và EndpointSlice trước, sau đó kiểm tra trạng thái target group trên AWS. Có thể thử đường nội bộ để phân biệt lỗi Kibana với lỗi ALB:

```bash
kubectl --context "$KUBE_CONTEXT" -n kibana get pods -l kibana.k8s.elastic.co/name=kibana -o wide
kubectl --context "$KUBE_CONTEXT" -n kibana get endpointslice -l kubernetes.io/service-name=kibana-kb-http -o yaml
kubectl --context "$KUBE_CONTEXT" -n kibana port-forward service/kibana-kb-http 5601:5601
# Chạy ở terminal khác: curl -vkI https://localhost:5601/
```

ALB hiện chỉ mở HTTP công khai. Trước khi dùng production, cấu hình chứng chỉ ACM cho hostname, thêm HTTPS listener và chuyển HTTP sang HTTPS; cân nhắc giới hạn CIDR truy cập bằng annotation `alb.ingress.kubernetes.io/inbound-cidrs`. ECK tiếp tục giữ TLS giữa ALB và Kibana.

Nếu Kibana không lên, kiểm tra `kubectl -n kibana describe kibana kibana`, `kubectl -n kibana describe pod -l kibana.k8s.elastic.co/name=kibana` và log của operator trong `elastic-system`. Cả hai namespace phải được cùng một ECK operator quản lý.

```shell
terraform init --backend-config=backend.tfvars -migrate-state

terraform plan --var-file=terraform.tfvars

terraform apply --var-file=terraform.tfvars --auto-approve

kubectl get nodes -L topology.kubernetes.io/zone

terraform destroy --auto-approve

# Nếu gặp lỗi lock state, có thể dùng lệnh sau để mở khóa (thay LOCK_ID bằng ID thực tế)
terraform force-unlock -force LOCK_ID
```

```shell
terraform init --backend-config=backend.tfvars -migrate-state

terraform plan --var-file=terraform.tfvars

terraform apply --var-file=terraform.tfvars --auto-approve

kubectl get nodes -L topology.kubernetes.io/zone

terraform destroy --auto-approve
```

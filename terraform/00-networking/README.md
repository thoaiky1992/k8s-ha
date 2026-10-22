```shell
terraform init --backend-config=backend.tfvars -migrate-state

terraform plan --var-file=terraform.tfvars
terraform apply --var-file=terraform.tfvars --auto-approve

terraform destroy --auto-approve
```
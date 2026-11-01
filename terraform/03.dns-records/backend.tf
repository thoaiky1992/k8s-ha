# chạy lại `terraform init -migrate-state` để đẩy state của chính nó lên cloud.
terraform {
  backend "s3" {
    bucket       = ""
    key          = ""
    region       = ""
    use_lockfile = true
    encrypt      = true
  }
}
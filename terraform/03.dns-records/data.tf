# Đọc remote state của tầng Networking
data "terraform_remote_state" "kubernetes" {
  backend = "s3"

  config = {
    bucket = var.kubernetes_state.bucket
    key    = var.kubernetes_state.key
    region = var.kubernetes_state.region
  }
}
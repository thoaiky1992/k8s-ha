# Đọc remote state của tầng Networking
data "terraform_remote_state" "networking" {
  backend = "s3"

  config = {
    bucket = var.networking_state.bucket
    key    = var.networking_state.key
    region = var.networking_state.region
  }
}
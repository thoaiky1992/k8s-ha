# Đọc remote state của tầng Networking
data "terraform_remote_state" "networking" {
  backend = "s3"

  config = {
    bucket = var.networking_state.bucket
    key    = var.networking_state.key
    region = var.networking_state.region
  }
}

# CIDR của các private subnet: Pod Kafka Connect dùng IP trong các subnet này (VPC CNI),
# nên security group của RDS chỉ cho phép các CIDR này truy cập cổng 5432.
data "aws_subnet" "private" {
  for_each = toset(data.terraform_remote_state.networking.outputs.values.private_subnet_ids)
  id       = each.value
}

data "aws_subnet" "public" {
  for_each = toset(data.terraform_remote_state.networking.outputs.values.public_subnet_ids)
  id       = each.value
}

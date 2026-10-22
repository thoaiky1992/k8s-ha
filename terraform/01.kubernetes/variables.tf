variable "region" {
  description = "Region của AWS nơi triển khai tài nguyên (mặc định cho VN thường dùng ap-southeast-1)."
  type        = string
}

variable "env" {
  description = "Môi trường triển khai ('dev', 'staging', 'prod', ...)."
  type        = string
}

variable "eks_name" {
  description = "Tên của EKS Cluster."
  type        = string
}

variable "eks_version" {
  description = "Phiên bản của EKS Cluster."
  type        = string
}

variable "route53_zone_names" {
  description = "Danh sách các tên miền Route53 cần tạo."
  type        = set(string)
}

variable "networking_state" {
  description = "Đường dẫn tới file state của networking (được tạo ra bởi terraform/00-networking)."
  type = object({
    bucket = string
    key    = string
    region = string
  })
}

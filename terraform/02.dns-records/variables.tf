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

variable "kubernetes_state" {
  description = "Đường dẫn tới file state của kubernetes (được tạo ra bởi terraform/01.kubernetes)."
  type        = object({
    bucket = string
    key    = string
    region = string
  })
}
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

variable "availability_zone_1" {
  description = "Các zone khả dụng để triển khai tài nguyên."
  type        = string
}

variable "availability_zone_2" {
  description = "Các zone khả dụng để triển khai tài nguyên."
  type        = string
}

variable "availability_zone_3" {
  description = "AZ thứ ba để triển khai subnet và node Elasticsearch."
  type        = string
}

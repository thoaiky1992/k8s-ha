variable "region" {
  description = "Region của AWS nơi triển khai RDS (mặc định cho VN thường dùng ap-southeast-1)."
  type        = string
}

variable "env" {
  description = "Môi trường triển khai ('dev', 'staging', 'prod', ...). Dùng làm tiền tố tên tài nguyên."
  type        = string
}

variable "networking_state" {
  description = "Đường dẫn tới file state của networking (được tạo ra bởi terraform/00-networking). RDS đặt trong private subnet của layer này."
  type = object({
    bucket = string
    key    = string
    region = string
  })
}

variable "db_identifier" {
  description = "Tên gốc của DB instance (chữ thường, số, dấu gạch ngang). Tên thật là '<env>-<db_identifier>', dùng cho instance, subnet group, security group, parameter group và snapshot cuối."
  type        = string
}

variable "db_name" {
  description = "Tên database được tạo sẵn khi khởi tạo instance. Connector Debezium đọc database này."
  type        = string
}

variable "db_master_username" {
  description = "User master của RDS (dùng cho cả instance và Multi-AZ DB cluster). Mật khẩu do random_string sinh và lưu trong SSM Parameter Store (03.rds-multi-cluster.tf)."
  type        = string
}

variable "db_cluster_instance_class" {
  description = "Class của từng instance trong Multi-AZ DB cluster (writer và hai reader). Phải là class hỗ trợ cluster, ví dụ db.m6gd.large."
  type        = string
}

variable "db_cluster_allocated_storage" {
  description = "Dung lượng gp3 (GiB) cho mỗi instance trong Multi-AZ DB cluster."
  type        = number
}

variable "db_engine_version" {
  description = "Phiên bản PostgreSQL đầy đủ (ví dụ 16.15). Phải thuộc cùng major với db_parameter_group_family."
  type        = string
}

variable "db_parameter_group_family" {
  description = "Family của parameter group, khớp major của db_engine_version (ví dụ postgres16)."
  type        = string
}

variable "db_instance_class" {
  description = "Class của DB instance (ví dụ db.m6i.large)."
  type        = string
}

variable "db_allocated_storage" {
  description = "Dung lượng gp3 ban đầu (GiB)."
  type        = number
}

variable "db_max_allocated_storage" {
  description = "Trần dung lượng RDS tự mở rộng (GiB). Đặt 0 để tắt autoscaling storage."
  type        = number
}

variable "db_backup_retention_period" {
  description = "Số ngày giữ automated backup (PITR). Phải lớn hơn 0 để bật được backup tự động của RDS."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Chặn xóa instance khi chưa tắt cờ này. Nên giữ true cho môi trường thật."
  type        = bool
  default     = true
}

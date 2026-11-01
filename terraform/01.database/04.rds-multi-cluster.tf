# # Parameter group cấp cluster. Multi-AZ DB cluster không dùng db_parameter_group của instance, nên rds.logical_replication phải đặt ở đây.
# resource "aws_rds_cluster_parameter_group" "kafka_connect" {
#   name        = "${var.env}-${var.db_identifier}-cluster-kafka-connect"
#   family      = var.db_parameter_group_family
#   description = "Logical replication cho Debezium (Kafka Connect), Multi-AZ DB cluster."

#   parameter {
#     name         = "rds.logical_replication"
#     value        = "1"
#     apply_method = "pending-reboot"
#   }

#   tags = {
#     Name = "${var.env}-${var.db_identifier}-cluster-kafka-connect"
#   }
# }

# # Multi-AZ DB cluster: một writer và hai reader đồng bộ, mỗi cái ở một AZ khác nhau.
# # Đặt db_cluster_instance_class mà không có cluster_members nghĩa là tạo Multi-AZ DB cluster (không phải Aurora).
# resource "aws_rds_cluster" "multi_az" {
#   cluster_identifier = "${var.env}-${var.db_identifier}-cluster"

#   engine         = "postgres"
#   engine_version = var.db_engine_version
#   # Class dùng cho cả writer và reader. Chỉ các class có hỗ trợ cluster mới dùng được (ví dụ db.m6gd.large).
#   db_cluster_instance_class = var.db_cluster_instance_class

#   # gp3 được Multi-AZ DB cluster hỗ trợ. Dung lượng là dung lượng cho mỗi instance trong cluster.
#   storage_type      = "gp3"
#   allocated_storage = var.db_cluster_allocated_storage
#   storage_encrypted = true

#   database_name   = var.db_name
#   master_username = var.db_master_username
#   master_password = random_string.db_master_password.result

#   db_subnet_group_name            = aws_db_subnet_group.this.name # Multi-AZ DB cluster không dùng db_subnet_group của instance, nên phải đặt ở đây.
#   vpc_security_group_ids          = [aws_security_group.rds.id] # Multi-AZ DB cluster không dùng vpc_security_group_ids của instance, nên phải đặt ở đây.
#   db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.kafka_connect.name
#   publicly_accessible             = false # Multi-AZ DB cluster không dùng publicly_accessible của instance, nên phải đặt ở đây. Nếu muốn public, set = true.

#   backup_retention_period = var.db_backup_retention_period # Số ngày giữ backup. 0 = không backup. AWS khuyến nghị >= 7 ngày.
#   copy_tags_to_snapshot   = true # Khi tạo snapshot, copy tags từ Multi-AZ DB cluster sang snapshot.
#   deletion_protection     = var.db_deletion_protection # Khi xóa Multi-AZ DB cluster, Terraform sẽ báo lỗi nếu deletion_protection = true. Nếu muốn xóa Multi-AZ DB cluster, set = false.

#   skip_final_snapshot       = false # Khi xóa Multi-AZ DB cluster, Terraform sẽ tạo snapshot cuối cùng. Nếu muốn xóa luôn mà không tạo snapshot, set = true.
#   final_snapshot_identifier = "${var.env}-${var.db_identifier}-cluster-final"

#   tags = {
#     Name = "${var.env}-${var.db_identifier}-cluster"
#   }
# }

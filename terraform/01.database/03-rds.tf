# Subnet group: RDS Multi-AZ cần subnet ở ít nhất 2 AZ; dùng cả 3 private subnet để standby có thể nằm ở AZ nào cũng được.
resource "aws_db_subnet_group" "this" {
  name       = "${var.env}-${var.db_identifier}"
  subnet_ids = data.terraform_remote_state.networking.outputs.values.public_subnet_ids

  tags = {
    Name = "${var.env}-${var.db_identifier}"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.env}-${var.db_identifier}-rds"
  description = "PostgreSQL for ${var.env}-${var.db_identifier}: accepts connections only from the private subnet."
  vpc_id      = data.terraform_remote_state.networking.outputs.values.vpc_id

  tags = {
    Name = "${var.env}-${var.db_identifier}-rds"
  }
}

# Chỉ mở cổng 5432 cho private subnet. Không có rule egress: RDS không cần đi ra ngoài.
resource "aws_vpc_security_group_ingress_rule" "postgres_from_private" {
  for_each = data.aws_subnet.private

  security_group_id = aws_security_group.rds.id
  description       = "PostgreSQL from ${each.value.availability_zone}"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value.cidr_block
}

resource "aws_vpc_security_group_ingress_rule" "postgres_from_public" {

  security_group_id = aws_security_group.rds.id
  description       = "PostgreSQL from public subnet (allows access from the Internet, e.g., DBeaver)."
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = "0.0.0.0/0"
}

# Parameter group riêng cho Debezium. rds.logical_replication = 1 đặt wal_level = logical.
# Tham số này là static: instance chỉ nhận giá trị mới sau khi reboot.
resource "aws_db_parameter_group" "kafka_connect" {
  name        = "${var.env}-${var.db_identifier}-kafka-connect"
  family      = var.db_parameter_group_family
  description = "Logical replication cho Debezium (Kafka Connect)."

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.env}-${var.db_identifier}-kafka-connect"
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.env}-${var.db_identifier}"

  engine         = "postgres"
  engine_version = var.db_engine_version # Dùng version mới nhất của PostgreSQL mà AWS RDS hỗ trợ. Nếu muốn dùng version cũ hơn, set ở terraform.tfvars.
  instance_class = var.db_instance_class # Dùng class hỗ trợ Multi-AZ, ví dụ db.m6gd.large. Không dùng db.m6i.large (không hỗ trợ Multi-AZ).

  db_name  = var.db_name
  username = var.db_master_username
  # Mật khẩu chung với Multi-AZ DB cluster, sinh và lưu ở 03.rds-multi-cluster.tf.
  password = random_string.db_master_password.result

  # Multi-AZ: RDS tạo một standby đồng bộ ở AZ khác. Failover tự động, endpoint giữ nguyên.
  # multi_az = true
  multi_az = false

  storage_type          = "gp3" # gp2: IOPS = 3 * GB, gp3: IOPS = 3 * GB, max IOPS = 16,000. gp3 rẻ hơn gp2 khi IOPS > 16,000.
  allocated_storage     = var.db_allocated_storage # Dung lượng ban đầu (GB). gp3: 20-64,000 GB. gp2: 20-16,000 GB.
  max_allocated_storage = var.db_max_allocated_storage # Dung lượng tối đa (GB). gp3: 20-64,000 GB. gp2: 20-16,000 GB. Nếu RDS cần thêm dung lượng, tự động tăng dung lượng đến max_allocated_storage.
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = true
  parameter_group_name   = aws_db_parameter_group.kafka_connect.name

  backup_retention_period    = var.db_backup_retention_period # Số ngày giữ backup. 0 = không backup. AWS khuyến nghị >= 7 ngày.
  backup_window              = "00:00-01:00" # Thời gian backup, UTC. Nếu không chỉ định, AWS sẽ chọn thời gian mặc định.
  copy_tags_to_snapshot      = true # Khi tạo snapshot, copy tags từ RDS sang snapshot.
  auto_minor_version_upgrade = true # Khi RDS có bản vá bảo mật, tự động nâng cấp minor version. Không nâng cấp major version.
  deletion_protection        = var.db_deletion_protection # Khi xóa RDS, Terraform sẽ báo lỗi nếu deletion_protection = true. Nếu muốn xóa RDS, set = false.

  skip_final_snapshot       = false # Khi xóa RDS, Terraform sẽ tạo snapshot cuối cùng. Nếu muốn xóa luôn mà không tạo snapshot, set = true.
  final_snapshot_identifier = "${var.env}-${var.db_identifier}-final"

  tags = {
    Name = "${var.env}-${var.db_identifier}"
  }
}

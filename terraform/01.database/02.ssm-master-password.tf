# Mật khẩu user master dùng chung cho RDS instance (02-rds.tf) và Multi-AZ DB cluster (file này).
# Sinh ngẫu nhiên. Lưu vào SSM Parameter Store ở 04.ssm-master-password.tf.
# Lưu ý: mật khẩu vẫn nằm trong Terraform state (S3, mã hóa), vì cả hai resource đều nhận mật khẩu dạng plaintext.
resource "random_string" "db_master_password" {
  length = 32
  # RDS không cho phép '/', '"', '@' và khoảng trắng trong mật khẩu master. Chỉ dùng các ký tự an toàn trong chuỗi kết nối.
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Lưu mật khẩu user master (sinh bởi random_string trong 03.rds-multi-cluster.tf) vào SSM Parameter Store dạng SecureString.
# Đây là nơi người vận hành đọc mật khẩu khi cần tạo user Debezium.
resource "aws_ssm_parameter" "db_master_password" {
  name        = "/${var.env}/${var.db_identifier}/master-password"
  description = "Password master (${var.db_master_username}) of ${var.env}-${var.db_identifier}."
  type        = "SecureString"
  value       = random_string.db_master_password.result
  tier        = "Standard"

  tags = {
    Name = "${var.env}-${var.db_identifier}-master-password"
  }
}

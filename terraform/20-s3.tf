resource "aws_s3_bucket" "this" {
  bucket        = "my-company-es-backups"   # Tên bucket S3 cần tạo
  acl           = "private"                 # Quyền truy cập mặc định cho bucket (private, public-read, public-read-write, authenticated-read)
  force_destroy = true                      # Cho phép xóa bucket kể cả khi còn dữ liệu bên
}

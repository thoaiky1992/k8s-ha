resource "aws_route53_zone" "this" {
  for_each = toset(local.route53_zone_names) # Lặp qua danh sách domain để tạo nhiều Hosted Zone

  name          = each.key                  # Tên miền cần quản lý (ví dụ: example.com)
  comment       = "Managed by Terraform"    # Ghi chú mô tả cho Hosted Zone
  force_destroy = true                      # Cho phép xóa zone kể cả khi còn bản ghi bên trong

  # Gắn thẻ nhận diện cho Hosted Zone trên giao diện AWS Console
  tags = merge(
    {
      Name        = each.key           # Tên nhãn hiển thị = tên miền
      Environment = local.env          # Môi trường triển khai (dev, stag, prod...)
      Project     = local.eks_name     # Tên dự án AWS
    }
  )
}
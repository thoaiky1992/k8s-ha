resource "aws_route53_zone" "this" {
  for_each = toset(var.route53_zone_names) # Lặp qua danh sách domain để tạo nhiều Hosted Zone

  name          = each.key               # Tên miền cần quản lý (ví dụ: example.com)
  comment       = "Managed by Terraform" # Ghi chú mô tả cho Hosted Zone
  force_destroy = true                   # Cho phép xóa zone kể cả khi còn bản ghi bên trong

  # Gắn thẻ nhận diện cho Hosted Zone trên giao diện AWS Console
  tags = merge(
    {
      Name        = each.key       # Tên nhãn hiển thị = tên miền
      Environment = var.env      # Môi trường triển khai (dev, stag, prod...)
      Project     = var.eks_name # Tên dự án AWS
    }
  )
}

resource "aws_acm_certificate" "this" {
  for_each          = toset(var.route53_zone_names)
  domain_name       = each.key
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for option in flatten([
      for certificate in aws_acm_certificate.this : certificate.domain_validation_options
      ]) : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  zone_id = aws_route53_zone.this[each.key].zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "this" {
  for_each        = aws_acm_certificate.this
  certificate_arn = each.value.arn
  validation_record_fqdns = [
    aws_route53_record.certificate_validation[each.key].fqdn
  ]
}

# Backup S3 cho RedisCluster (prefix redis-cluster/).
# nhưng dùng bucket riêng để quyền và vòng đời dữ liệu của hai cụm tách biệt.
# Đặt tên bucket duy nhất toàn cục trong terraform.tfvars: redis_cluster_backup_bucket_name = "..."

variable "redis_cluster_backup_bucket_name" {
  description = "Tên S3 bucket cho backup RedisCluster. Phải duy nhất toàn cục."
  type        = string
  default     = "dev-demo-redis-cluster-backup"
}

variable "redis_cluster_backup_retention_days" {
  description = "Số ngày giữ backup RedisCluster trên S3."
  type        = number
  default     = 30
}

resource "aws_s3_bucket" "redis_cluster_backup" {
  bucket        = var.redis_cluster_backup_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "redis_cluster_backup" {
  bucket = aws_s3_bucket.redis_cluster_backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "redis_cluster_backup" {
  bucket = aws_s3_bucket.redis_cluster_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "redis_cluster_backup_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.redis_cluster_backup.arn,
      "${aws_s3_bucket.redis_cluster_backup.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "redis_cluster_backup" {
  bucket = aws_s3_bucket.redis_cluster_backup.id
  policy = data.aws_iam_policy_document.redis_cluster_backup_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.redis_cluster_backup]
}

resource "aws_s3_bucket_versioning" "redis_cluster_backup" {
  bucket = aws_s3_bucket.redis_cluster_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "redis_cluster_backup" {
  bucket = aws_s3_bucket.redis_cluster_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "redis_cluster_backup" {
  bucket = aws_s3_bucket.redis_cluster_backup.id

  depends_on = [aws_s3_bucket_versioning.redis_cluster_backup]

  rule {
    id     = "dev-demo-redis-cluster-backup-retention"
    status = "Enabled"

    filter {
      prefix = "redis-cluster/"
    }

    expiration {
      days = var.redis_cluster_backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.redis_cluster_backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "redis_cluster_backup_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "redis_cluster_backup" {
  name               = "${aws_eks_cluster.eks.name}-dev-demo-redis-cluster-backup"
  assume_role_policy = data.aws_iam_policy_document.redis_cluster_backup_assume_role.json
}

data "aws_iam_policy_document" "redis_cluster_backup" {
  statement {
    sid       = "GetBackupBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.redis_cluster_backup.arn]
  }

  statement {
    sid    = "ListBackupPrefix"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.redis_cluster_backup.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["redis-cluster/*"]
    }
  }

  statement {
    sid    = "ReadWriteBackupObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.redis_cluster_backup.arn}/redis-cluster/*"]
  }
}

resource "aws_iam_policy" "redis_cluster_backup" {
  name   = "${aws_eks_cluster.eks.name}-dev-demo-redis-cluster-backup"
  policy = data.aws_iam_policy_document.redis_cluster_backup.json
}

resource "aws_iam_role_policy_attachment" "redis_cluster_backup" {
  role       = aws_iam_role.redis_cluster_backup.name
  policy_arn = aws_iam_policy.redis_cluster_backup.arn
}

resource "aws_eks_pod_identity_association" "redis_cluster_backup" {
  cluster_name    = aws_eks_cluster.eks.name
  namespace       = "redis-cluster"
  service_account = "dev-demo-redis-cluster-backup"
  role_arn        = aws_iam_role.redis_cluster_backup.arn

  depends_on = [aws_eks_addon.pod_identity]
}

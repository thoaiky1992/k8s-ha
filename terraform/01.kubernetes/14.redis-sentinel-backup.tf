locals {
  redis_sentinel_backup_bucket_name = "redis-sentinel-backup"
  redis_sentinel_backup_retention_days = 30
}

resource "aws_s3_bucket" "redis_sentinel_backup" {
  bucket        = local.redis_sentinel_backup_bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_ownership_controls" "redis_sentinel_backup" {
  bucket = aws_s3_bucket.redis_sentinel_backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "redis_sentinel_backup" {
  bucket = aws_s3_bucket.redis_sentinel_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "redis_sentinel_backup_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.redis_sentinel_backup.arn,
      "${aws_s3_bucket.redis_sentinel_backup.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "redis_sentinel_backup" {
  bucket = aws_s3_bucket.redis_sentinel_backup.id
  policy = data.aws_iam_policy_document.redis_sentinel_backup_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.redis_sentinel_backup]
}

resource "aws_s3_bucket_versioning" "redis_sentinel_backup" {
  bucket = aws_s3_bucket.redis_sentinel_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "redis_sentinel_backup" {
  bucket = aws_s3_bucket.redis_sentinel_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "redis_sentinel_backup" {
  bucket = aws_s3_bucket.redis_sentinel_backup.id

  depends_on = [aws_s3_bucket_versioning.redis_sentinel_backup]

  rule {
    id     = "redis-sentinel-backup-retention"
    status = "Enabled"

    filter {
      prefix = "redis-sentinel/"
    }

    expiration {
      days = local.redis_sentinel_backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = local.redis_sentinel_backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "redis_sentinel_backup_assume_role" {
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

resource "aws_iam_role" "redis_sentinel_backup" {
  name               = "${aws_eks_cluster.eks.name}-redis-sentinel-backup"
  assume_role_policy = data.aws_iam_policy_document.redis_sentinel_backup_assume_role.json
}

data "aws_iam_policy_document" "redis_sentinel_backup" {
  statement {
    sid       = "GetBackupBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.redis_sentinel_backup.arn]
  }

  statement {
    sid    = "ListBackupPrefix"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.redis_sentinel_backup.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["redis-sentinel/*"]
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
    resources = ["${aws_s3_bucket.redis_sentinel_backup.arn}/redis-sentinel/*"]
  }
}

resource "aws_iam_policy" "redis_sentinel_backup" {
  name   = "${aws_eks_cluster.eks.name}-redis-sentinel-backup"
  policy = data.aws_iam_policy_document.redis_sentinel_backup.json
}

resource "aws_iam_role_policy_attachment" "redis_sentinel_backup" {
  role       = aws_iam_role.redis_sentinel_backup.name
  policy_arn = aws_iam_policy.redis_sentinel_backup.arn
}

resource "aws_eks_pod_identity_association" "redis_sentinel_backup" {
  cluster_name    = aws_eks_cluster.eks.name
  namespace       = "redis-sentinel"
  service_account = "redis-sentinel-backup"
  role_arn        = aws_iam_role.redis_sentinel_backup.arn

  depends_on = [aws_eks_addon.pod_identity]
}

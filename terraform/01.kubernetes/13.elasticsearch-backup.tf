
resource "aws_s3_bucket" "this" {
  bucket        = "my-company-es-backups"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_acl" "this" {
  depends_on = [
    aws_s3_bucket_ownership_controls.this,
    aws_s3_bucket_public_access_block.this,
  ]

  bucket = aws_s3_bucket.this.id
  acl    = "private" // Change to "private" if you want to restrict access
}

data "aws_iam_policy_document" "elasticsearch_snapshot_assume_role" {
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

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [aws_eks_cluster.eks.name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["elasticsearch"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["elasticsearch-s3"]
    }
  }
}

resource "aws_iam_role" "elasticsearch_snapshot" {
  name               = "${aws_eks_cluster.eks.name}-elasticsearch-snapshot"
  assume_role_policy = data.aws_iam_policy_document.elasticsearch_snapshot_assume_role.json
}

data "aws_iam_policy_document" "elasticsearch_snapshot" {
  statement {
    sid       = "GetSnapshotBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid    = "ListSnapshotPrefix"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListBucketVersions",
    ]
    resources = [aws_s3_bucket.this.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "production/search",
        "production/search/*",
      ]
    }
  }

  statement {
    sid    = "ReadWriteSnapshotObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.this.arn}/production/search/*"]
  }
}

resource "aws_iam_policy" "elasticsearch_snapshot" {
  name   = "${aws_eks_cluster.eks.name}-elasticsearch-snapshot"
  policy = data.aws_iam_policy_document.elasticsearch_snapshot.json
}

resource "aws_iam_role_policy_attachment" "elasticsearch_snapshot" {
  role       = aws_iam_role.elasticsearch_snapshot.name
  policy_arn = aws_iam_policy.elasticsearch_snapshot.arn
}

resource "aws_eks_pod_identity_association" "elasticsearch_snapshot" {
  cluster_name    = aws_eks_cluster.eks.name
  namespace       = "elasticsearch"
  service_account = "elasticsearch-s3"
  role_arn        = aws_iam_role.elasticsearch_snapshot.arn

  depends_on = [
    aws_eks_addon.pod_identity,
    aws_iam_role_policy_attachment.elasticsearch_snapshot,
  ]
}

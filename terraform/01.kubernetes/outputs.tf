output "values" {
  value = {
    eks = {
      cluster_name                       = aws_eks_cluster.eks.name
      cluster_arn                        = aws_eks_cluster.eks.arn
      cluster_endpoint                   = aws_eks_cluster.eks.endpoint
      cluster_certificate_authority_data = aws_eks_cluster.eks.certificate_authority[0].data
      nodes = {
        node_group_name     = aws_eks_node_group.general.node_group_name
        node_role_arn       = aws_eks_node_group.general.node_role_arn
        node_instance_types = aws_eks_node_group.general.instance_types
        node_capacity_type  = aws_eks_node_group.general.capacity_type
      }
    }
    route53 = {
      for k, v in aws_route53_zone.this : k => {
        "arn"             = v.arn
        "id"              = v.id
        "zone_id"         = v.zone_id
        "name"            = v.name
        "certificate_arn" = aws_acm_certificate_validation.this[k].certificate_arn
      }
    }
    redis_sentinel_backup = {
      bucket_name = aws_s3_bucket.redis_sentinel_backup.id
      role_arn    = aws_iam_role.redis_sentinel_backup.arn
    }
    elasticsearch_snapshot = {
      bucket_name = aws_s3_bucket.this.id
      role_arn    = aws_iam_role.elasticsearch_snapshot.arn
    }
  }
}

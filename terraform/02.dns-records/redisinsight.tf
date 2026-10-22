locals {
  redisinsight_domain = "aws-redisinsight.thoaiky.com"
}


############################################
# Create an alias record in Route 53 that points to the RedisInsight load balancer
############################################
data "aws_lb" "redisinsight" {
  tags = {
    "elbv2.k8s.aws/cluster" = data.terraform_remote_state.kubernetes.outputs.values.eks.cluster_name
    "ingress.k8s.aws/stack" = "redis-sentinel/redisinsight"
  }
}

resource "aws_route53_record" "redisinsight_alias" {

  zone_id = data.terraform_remote_state.kubernetes.outputs.values.route53[local.redisinsight_domain].zone_id
  name    = local.redisinsight_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.redisinsight.dns_name
    zone_id                = data.aws_lb.redisinsight.zone_id
    evaluate_target_health = true
  }
}

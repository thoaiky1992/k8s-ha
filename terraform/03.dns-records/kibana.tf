# locals {
#   kibana_domain = "aws-kibana.thoaiky.com"
# }


# ############################################
# # Create an alias record in Route 53 that points to the Kibana load balancer
# ############################################
# data "aws_lb" "kibana" {
#   tags = {
#     "elbv2.k8s.aws/cluster" = data.terraform_remote_state.kubernetes.outputs.values.eks.cluster_name
#     "ingress.k8s.aws/stack" = "kibana/kibana"
#   }
# }

# resource "aws_route53_record" "kibana_alias" {

#   zone_id = data.terraform_remote_state.kubernetes.outputs.values.route53[local.kibana_domain].zone_id
#   name    = local.kibana_domain
#   type    = "A"

#   alias {
#     name                   = data.aws_lb.kibana.dns_name
#     zone_id                = data.aws_lb.kibana.zone_id
#     evaluate_target_health = true
#   }
# }

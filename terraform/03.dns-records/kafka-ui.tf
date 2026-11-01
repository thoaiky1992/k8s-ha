locals {
  kafka_ui_domain = "aws-kafka-ui.thoaiky.com"
}

data "aws_route53_zone" "kafka_ui" {
  name         = local.kafka_ui_domain
  private_zone = false
}

data "aws_lb" "kafka_ui" {
  tags = {
    "ingress.k8s.aws/stack" = "kafka/kafka-ui"
  }
}

resource "aws_route53_record" "kafka_ui_alias" {
  zone_id = data.aws_route53_zone.kafka_ui.zone_id
  name    = local.kafka_ui_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.kafka_ui.dns_name
    zone_id                = data.aws_lb.kafka_ui.zone_id
    evaluate_target_health = true
  }
}

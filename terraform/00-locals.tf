locals {
  env         = "dev"
  region      = "ap-southeast-1"
  zone1       = "ap-southeast-1a"
  zone2       = "ap-southeast-1b"
  eks_name    = "demo"
  eks_version = "1.37"
  route53_zone_names = ["aws-kibana.thoaiky.com"]
}
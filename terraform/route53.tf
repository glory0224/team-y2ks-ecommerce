variable "domain_name" {
  description = "Route53에 등록된 도메인 이름 (y2ks-frontend-svc ELB와 연결)"
  type        = string
  default     = "y2ks.site"
}

data "aws_route53_zone" "main" {
  name = var.domain_name
}

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
  default     = "y2ks-eks-cluster"
}

variable "amp_workspace_alias" {
  description = "AMP workspace alias"
  type        = string
  default     = "y2ks-amp"
}

variable "amg_workspace_name" {
  description = "AMG workspace 이름"
  type        = string
  default     = "y2ks-grafana"
}

variable "sso_instance_arn" {
  description = "IAM Identity Center instance ARN"
  type        = string
  default     = "arn:aws:sso:::instance/ssoins-7230cebb156a0551"
}

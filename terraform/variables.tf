variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "y2ks-cluster"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

# account_id is removed - use data.aws_caller_identity.current.account_id in main.tf

variable "sender_email" {
  description = "SES sender email (must be verified in SES)"
  type        = string
  default     = "wooseoyun@naver.com"
}

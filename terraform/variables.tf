variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
  default     = "y2ks-eks-cluster"
}

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "kubernetes_version" {
  description = "Kubernetes 버전"
  type        = string
  default     = "1.31"
}

variable "account_id" {
  description = "AWS 계정 ID"
  type        = string
  default     = "314240764197"
}

variable "sender_email" {
  description = "SES 발신 이메일 (SES에서 인증된 이메일)"
  type        = string
  default     = "wooseoyun@naver.com"
}

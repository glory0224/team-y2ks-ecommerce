variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
  default     = "my-eks-cluster"
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

# account_id는 variables.tf에서 제거 - main.tf의 data.aws_caller_identity.current.account_id 사용

variable "sender_email" {
  description = "SES 발신 이메일 (SES에서 인증된 이메일)"
  type        = string
  default     = "wooseoyun@naver.com"
}

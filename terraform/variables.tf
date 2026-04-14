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

variable "sender_email" {
  description = "SES 발신 이메일 (SES에서 인증된 이메일)"
  type        = string
  default     = "wooseoyun@naver.com"
}

variable "team_member_usernames" {
  description = "EKS 클러스터 접근 권한을 부여할 IAM 유저명 목록 (terraform apply 시 자동으로 kubectl 권한 부여)"
  type        = list(string)
  default     = ["user01", "user02", "user03", "user04"]
}

variable "grafana_admin_password" {
  description = "Grafana admin 비밀번호"
  type        = string
  default     = "admin123!"
  sensitive   = true
}

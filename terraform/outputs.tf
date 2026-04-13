# ============================================================
# 클러스터 정보
# ============================================================
output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트"
  value       = aws_eks_cluster.main.endpoint
}

output "oidc_issuer" {
  description = "OIDC Issuer URL (https:// 제거된 버전)"
  value       = local.oidc_issuer
}

# ============================================================
# kubeconfig 업데이트 명령어
# ============================================================
output "kubeconfig_command" {
  description = "클러스터 생성 후 실행할 명령어"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}

# ============================================================
# kubectl 적용 시 필요한 ARN 값들
# ============================================================
output "worker_role_arn" {
  description = "worker-sa ServiceAccount에 annotate할 IAM Role ARN"
  value       = aws_iam_role.worker.arn
}

output "keda_operator_role_arn" {
  description = "keda-operator ServiceAccount에 annotate할 IAM Role ARN"
  value       = aws_iam_role.keda_operator.arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter Helm 설치 시 사용할 IAM Role ARN"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_arn" {
  description = "karpenter-nodepool.yaml의 role 필드에 사용"
  value       = aws_iam_role.karpenter_node.name
}

# ============================================================
# 이후 kubectl 작업 안내
# ============================================================
output "next_steps" {
  description = "terraform apply 완료 후 실행 순서"
  value       = <<-EOT
    [terraform apply 한 번으로 자동 완료]
    - VPC / EKS / IAM 생성
    - DynamoDB 테이블 생성 (y2ks-coupon-claims)
    - SQS 큐 생성 (y2ks-queue)
    - ECR 리포지토리 생성 + Docker 이미지 빌드 & 푸시
    - Prometheus Helm 설치 (monitoring 네임스페이스)
    - KEDA Helm 설치
    - Karpenter Helm 설치
    - worker-sa 생성 + IRSA 어노테이션
    - Y2KS 앱 전체 배포 (Helm)
    - 계정 ID는 aws configure에서 자동으로 읽어옴
    - variables.tf의 team_member_usernames 등록된 팀원은 kubectl 권한 자동 부여

    [팀원이 처음 설정할 것]
    1. aws configure (본인 IAM 자격증명 입력)
    2. kubeconfig 업데이트:
       aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}
    3. 접속 URL 확인:
       kubectl get svc y2ks-frontend-svc

    [쿠폰 수량 변경]
    helm/y2ks/values.yaml 의 ticketCount 수정 후 terraform apply

    [코드 수정 후 재배포]
    terraform apply

    [전체 삭제]
    terraform destroy
    (Karpenter 노드 → LoadBalancer → ELB → ENI 순서로 자동 정리됨)
  EOT
}

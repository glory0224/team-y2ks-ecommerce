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

output "sqs_queue_url" {
  description = "app-deployment.yaml ConfigMap에 주입할 SQS URL"
  value       = "https://sqs.${var.aws_region}.amazonaws.com/${data.aws_caller_identity.current.account_id}/y2ks-queue"
}

output "account_id" {
  description = "현재 aws configure에 설정된 계정 ID"
  value       = data.aws_caller_identity.current.account_id
}

# ============================================================
# 이후 kubectl 작업 안내
# ============================================================
output "next_steps" {
  description = "terraform apply 완료 후 실행 순서"
  value       = <<-EOT
    1. kubeconfig 업데이트:
       aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}

    2. worker-sa ServiceAccount 생성 및 IRSA 연결:
       kubectl create serviceaccount worker-sa
       kubectl annotate serviceaccount worker-sa \
         eks.amazonaws.com/role-arn=${aws_iam_role.worker.arn}

    3. 앱 배포:
       kubectl apply -f redis.yaml
       AWS_ACCOUNT_ID=$(terraform output -raw account_id) envsubst < app-deployment.yaml | kubectl apply -f -

    4. KEDA 설치:
       helm install keda kedacore/keda --namespace keda --create-namespace
       kubectl annotate serviceaccount keda-operator -n keda \
         eks.amazonaws.com/role-arn=${aws_iam_role.keda_operator.arn}
       kubectl apply -f keda-scaledobject.yaml

    5. Karpenter 설치:
       helm install karpenter ... --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${aws_iam_role.karpenter_controller.arn}
       kubectl apply -f karpenter-nodepool.yaml
  EOT
}

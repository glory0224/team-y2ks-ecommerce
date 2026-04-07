# ============================================================
# Cluster info
# ============================================================
output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "oidc_issuer" {
  description = "OIDC Issuer URL (without https:// prefix)"
  value       = local.oidc_issuer
}

# ============================================================
# kubeconfig update command
# ============================================================
output "kubeconfig_command" {
  description = "Run this after cluster creation to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}

# ============================================================
# ARN values needed for kubectl steps
# ============================================================
output "worker_role_arn" {
  description = "IAM Role ARN to annotate on worker-sa ServiceAccount"
  value       = aws_iam_role.worker.arn
}

output "keda_operator_role_arn" {
  description = "IAM Role ARN to annotate on keda-operator ServiceAccount"
  value       = aws_iam_role.keda_operator.arn
}

output "karpenter_controller_role_arn" {
  description = "IAM Role ARN used during Karpenter Helm install"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_node_role_arn" {
  description = "IAM Role name used in karpenter-nodepool.yaml"
  value       = aws_iam_role.karpenter_node.name
}

output "sqs_queue_url" {
  description = "SQS URL injected into app-deployment.yaml ConfigMap"
  value       = "https://sqs.${var.aws_region}.amazonaws.com/${data.aws_caller_identity.current.account_id}/y2ks-queue"
}

output "account_id" {
  description = "AWS account ID from current aws configure profile"
  value       = data.aws_caller_identity.current.account_id
}

# ============================================================
# Post-apply instructions
# ============================================================
output "next_steps" {
  description = "Steps to run after terraform apply"
  value       = <<-EOT
    1. Update kubeconfig:
       aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}

    2. Create worker-sa ServiceAccount and attach IRSA:
       kubectl create serviceaccount worker-sa
       kubectl annotate serviceaccount worker-sa \
         eks.amazonaws.com/role-arn=${aws_iam_role.worker.arn}

    3. Deploy apps:
       kubectl apply -f redis.yaml
       AWS_ACCOUNT_ID=$(terraform output -raw account_id) envsubst < app-deployment.yaml | kubectl apply -f -

    4. Install KEDA:
       helm install keda kedacore/keda --namespace keda --create-namespace
       kubectl annotate serviceaccount keda-operator -n keda \
         eks.amazonaws.com/role-arn=${aws_iam_role.keda_operator.arn}
       AWS_ACCOUNT_ID=$(terraform output -raw account_id) envsubst < keda-scaledobject.yaml | kubectl apply -f -

    5. Install Karpenter:
       bash deploy.sh
  EOT
}

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# aws configure에서 현재 계정 ID를 자동으로 읽어옴
data "aws_caller_identity" "current" {}

# ============================================================
# 사전 요구사항 확인 — aws cli, kubectl, helm 설치 여부
# 하나라도 없으면 이후 모든 단계가 실패하므로 가장 먼저 실행
# ============================================================
resource "null_resource" "check_prerequisites" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      echo "=== 사전 요구사항 확인 ==="
      if ! aws --version > /dev/null 2>&1; then
        echo "[ERROR] aws cli가 설치되어 있지 않습니다. https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
      fi
      echo "[OK] aws cli: $(aws --version 2>&1)"

      if ! kubectl version --client > /dev/null 2>&1; then
        echo "[ERROR] kubectl이 설치되어 있지 않습니다. https://kubernetes.io/docs/tasks/tools/"
        exit 1
      fi
      echo "[OK] kubectl: $(kubectl version --client 2>&1 | head -1)"

      if ! helm version > /dev/null 2>&1; then
        echo "[ERROR] helm이 설치되어 있지 않습니다. https://helm.sh/docs/intro/install/"
        exit 1
      fi
      echo "[OK] helm: $(helm version --short 2>&1)"

      echo "=== 모든 사전 요구사항 충족 ==="
    EOT
  }
}

# ============================================================
# kubeconfig 업데이트 — 모든 K8s 작업의 시작점
# ============================================================
resource "null_resource" "kubeconfig" {
  triggers = {
    cluster_name = aws_eks_cluster.main.name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.aws_region}"
  }

  depends_on = [
    null_resource.check_prerequisites,
    aws_eks_addon.metrics_server,
    aws_eks_addon.coredns,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.vpc_cni,
    aws_eks_access_entry.terraform_runner,
    aws_eks_access_policy_association.terraform_runner_admin,
  ]
}

# ============================================================
# KEDA 설치 (helm CLI 직접 실행)
# ============================================================
resource "null_resource" "install_keda" {
  triggers = {
    cluster_name = aws_eks_cluster.main.name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      helm repo add kedacore https://kedacore.github.io/charts
      helm repo update
      helm upgrade --install keda kedacore/keda \
        --namespace keda --create-namespace \
        --version 2.16.0 \
        --wait --timeout 5m
    EOT
  }

  depends_on = [null_resource.kubeconfig]
}

# ============================================================
# Karpenter 설치 (helm CLI 직접 실행)
# ============================================================
resource "null_resource" "install_karpenter" {
  triggers = {
    cluster_name = aws_eks_cluster.main.name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --version 1.1.1 \
        --namespace karpenter --create-namespace \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${aws_iam_role.karpenter_controller.arn}" \
        --set "settings.clusterName=${var.cluster_name}" \
        --set "settings.clusterEndpoint=${aws_eks_cluster.main.endpoint}" \
        --set "settings.interruptionQueue=KarpenterInterruption-${var.cluster_name}" \
        --wait --timeout 5m
    EOT
  }

  depends_on = [null_resource.kubeconfig]
}

# ============================================================
# worker-sa + IRSA 어노테이션
# KEDA operator SA에도 IAM Role 어노테이션
# ============================================================
resource "null_resource" "service_accounts" {
  triggers = {
    worker_role_arn = aws_iam_role.worker.arn
    keda_role_arn   = aws_iam_role.keda_operator.arn
    cluster_name    = aws_eks_cluster.main.name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      kubectl create serviceaccount worker-sa --dry-run=client -o yaml | kubectl apply -f -
      kubectl annotate serviceaccount worker-sa \
        eks.amazonaws.com/role-arn=${aws_iam_role.worker.arn} \
        --overwrite
      kubectl annotate serviceaccount keda-operator -n keda \
        eks.amazonaws.com/role-arn=${aws_iam_role.keda_operator.arn} \
        --overwrite
    EOT
  }

  depends_on = [null_resource.install_keda]
}

# ============================================================
# Y2KS 앱 배포 (helm CLI 직접 실행)
# aws configure의 계정 ID가 자동으로 주입됨
# ============================================================
resource "null_resource" "install_y2ks" {
  triggers = {
    account_id          = data.aws_caller_identity.current.account_id
    cluster_name        = var.cluster_name
    karpenter_node_role = aws_iam_role.karpenter_node.name
    # 템플릿 파일 변경 감지 → terraform apply 시 자동 재배포
    config_hash = sha256(join("", [
      file("${path.module}/../helm/y2ks/templates/aws-config.yaml"),
      file("${path.module}/../helm/y2ks/templates/frontend.yaml"),
      file("${path.module}/../helm/y2ks/templates/worker.yaml"),
      file("${path.module}/../helm/y2ks/templates/keda.yaml"),
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      kubectl wait --for=condition=established crd/scaledobjects.keda.sh --timeout=120s
      kubectl wait --for=condition=established crd/triggerauthentications.keda.sh --timeout=120s
      helm upgrade --install y2ks ${path.module}/../helm/y2ks \
        --namespace default \
        --set accountId=${data.aws_caller_identity.current.account_id} \
        --set region=${var.aws_region} \
        --set clusterName=${var.cluster_name} \
        --set workerRoleArn=${aws_iam_role.worker.arn} \
        --set karpenterNodeRoleName=${aws_iam_role.karpenter_node.name}
    EOT
  }

  depends_on = [null_resource.service_accounts, null_resource.install_karpenter]
}

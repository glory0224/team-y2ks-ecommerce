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

  backend "s3" {
    bucket         = "y2ks-terraform-state-951913065915"
    key            = "terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "y2ks-terraform-lock"
    encrypt        = true
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
  triggers = {
    script_hash = sha256(<<-EOT
      aws --version
      kubectl version --client
      helm version
    EOT
    )
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      Write-Host "=== 사전 요구사항 확인 ==="

      & aws --version 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] aws cli가 설치되어 있지 않습니다. https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
      }
      Write-Host "[OK] aws cli"

      & kubectl version --client 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] kubectl이 설치되어 있지 않습니다. https://kubernetes.io/docs/tasks/tools/"
        exit 1
      }
      Write-Host "[OK] kubectl"

      & helm version 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] helm이 설치되어 있지 않습니다. https://helm.sh/docs/intro/install/"
        exit 1
      }
      Write-Host "[OK] helm"

      Write-Host "=== 모든 사전 요구사항 충족 ==="
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
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
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
# Prometheus 설치 (helm CLI 직접 실행)
# frontend의 admin 메트릭 엔드포인트가 prometheus-server.monitoring:80 참조
# ============================================================
resource "null_resource" "install_prometheus" {
  triggers = {
    cluster_name = aws_eks_cluster.main.name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = "helm uninstall prometheus --namespace monitoring 2>$null; exit 0"
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
      helm repo update
      helm uninstall prometheus --namespace monitoring 2>$null
      kubectl delete pvc --all -n monitoring 2>$null
      Start-Sleep -Seconds 5
      helm upgrade --install prometheus prometheus-community/prometheus `
        --namespace monitoring --create-namespace `
        --set server.persistentVolume.enabled=false `
        --set alertmanager.enabled=false `
        --set prometheus-node-exporter.enabled=false `
        --wait --timeout 5m
    EOT
  }

  depends_on = [null_resource.kubeconfig]
}

# ============================================================
# KEDA 설치 (helm CLI 직접 실행)
# ============================================================
resource "null_resource" "install_keda" {
  triggers = {
    cluster_name = aws_eks_cluster.main.name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = "helm uninstall keda --namespace keda 2>$null; exit 0"
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      helm repo add kedacore https://kedacore.github.io/charts
      helm repo update
      helm upgrade --install keda kedacore/keda `
        --namespace keda --create-namespace `
        --version 2.16.0 `
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
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = "helm uninstall karpenter --namespace karpenter 2>$null; exit 0"
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter `
        --version 1.1.1 `
        --namespace karpenter --create-namespace `
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${aws_iam_role.karpenter_controller.arn}" `
        --set "settings.clusterName=${var.cluster_name}" `
        --set "settings.clusterEndpoint=${aws_eks_cluster.main.endpoint}" `
        --set "settings.interruptionQueue=KarpenterInterruption-${var.cluster_name}" `
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
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      kubectl create serviceaccount worker-sa --dry-run=client -o yaml | kubectl apply -f -
      kubectl annotate serviceaccount worker-sa `
        eks.amazonaws.com/role-arn=${aws_iam_role.worker.arn} `
        --overwrite
      kubectl annotate serviceaccount keda-operator -n keda `
        eks.amazonaws.com/role-arn=${aws_iam_role.keda_operator.arn} `
        --overwrite
      # IRSA 어노테이션 적용 후 keda-operator 재시작 — 토큰 재마운트
      kubectl rollout restart deployment/keda-operator -n keda
      kubectl rollout status deployment/keda-operator -n keda --timeout=120s
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
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      Write-Host "=== [1/3] Karpenter 노드 정리 ==="
      kubectl delete nodepool --all --ignore-not-found
      kubectl delete ec2nodeclass --all --ignore-not-found

      Write-Host "=== [2/3] Karpenter 노드 drain 대기 (최대 3분) ==="
      $timeout = 180
      $elapsed = 0
      while ($elapsed -lt $timeout) {
        $nodes = kubectl get nodes -l karpenter.sh/nodepool --no-headers --request-timeout=10s 2>$null
        if (-not $nodes) { Write-Host "Karpenter 노드 정리 완료"; break }
        Write-Host "노드 정리 대기 중... ($elapsed s)"
        Start-Sleep -Seconds 10
        $elapsed += 10
      }

      Write-Host "=== [3/3] Y2KS 앱 삭제 (LoadBalancer → ELB → ENI 정리) ==="
      helm uninstall y2ks --namespace default 2>$null
      Write-Host "ELB 삭제 대기 중 (30초)..."
      Start-Sleep -Seconds 30
      Write-Host "=== Y2KS 정리 완료 ==="
    EOT
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      kubectl wait --for=condition=established crd/scaledobjects.keda.sh --timeout=120s
      kubectl wait --for=condition=established crd/triggerauthentications.keda.sh --timeout=120s
      kubectl wait --for=condition=established crd/ec2nodeclasses.karpenter.k8s.aws --timeout=120s
      kubectl wait --for=condition=established crd/nodepools.karpenter.sh --timeout=120s
      helm upgrade --install y2ks ${path.module}/../helm/y2ks `
        --namespace default `
        --set accountId=${data.aws_caller_identity.current.account_id} `
        --set region=${var.aws_region} `
        --set clusterName=${var.cluster_name} `
        --set workerRoleArn=${aws_iam_role.worker.arn} `
        --set karpenterNodeRoleName=${aws_iam_role.karpenter_node.name} `
        --set images.frontend=${aws_ecr_repository.frontend.repository_url}:latest `
        --set images.worker=${aws_ecr_repository.worker.repository_url}:latest
    EOT
  }

  depends_on = [null_resource.service_accounts, null_resource.install_karpenter, null_resource.install_prometheus, null_resource.build_and_push_images]
}

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

# kube-prometheus-stack (AMP remote_write 포함) 은
# monitoring/ 디렉토리의 terraform에서 설치됩니다.

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
    command     = "helm uninstall keda --namespace keda --timeout 2m0s 2>$null; exit 0"
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      helm repo add kedacore https://kedacore.github.io/charts
      helm repo update
      helm upgrade --install keda kedacore/keda `
        --namespace keda --create-namespace `
        --set prometheus.operator.enabled=true `
        --set prometheus.operator.port=8080 `
        --set prometheus.metricServer.enabled=true `
        --set prometheus.metricServer.port=9022 `
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
    command     = "helm uninstall karpenter --namespace karpenter --timeout 2m0s 2>$null; exit 0"
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
      Write-Host "=== [1/3] Karpenter ASG 직접 삭제 ==="
      # Karpenter가 만든 ASG를 AWS CLI로 직접 삭제 (Karpenter가 죽어있어도 동작)
      $asgs = aws autoscaling describe-auto-scaling-groups `
        --query "AutoScalingGroups[?contains(Tags[?Key=='karpenter.sh/nodepool'].Value, 'default')].AutoScalingGroupName" `
        --output text 2>$null
      if ($asgs) {
        foreach ($asg in $asgs -split "`t") {
          if ($asg) {
            Write-Host "ASG 삭제 중: $asg"
            aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $asg --force-delete
          }
        }
        Write-Host "ASG 삭제 요청 완료. EC2 terminate 대기 중 (60초)..."
        Start-Sleep -Seconds 60
      } else {
        Write-Host "Karpenter ASG 없음 — 건너뜀"
      }

      Write-Host "=== [2/3] Y2KS 앱 삭제 (LoadBalancer → ELB → ENI 정리) ==="
      helm uninstall y2ks --namespace default --timeout 2m0s 2>$null

      Write-Host "ELB 삭제 확인 중 (최대 3분)..."
      $vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${self.triggers.cluster_name}-vpc" --query "Vpcs[0].VpcId" --output text 2>$null
      $timeout = 180
      $elapsed = 0
      while ($elapsed -lt $timeout) {
        $classicElbs = (aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='$vpcId'].LoadBalancerName" --output text 2>$null)
        $v2Elbs = (aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$vpcId'].LoadBalancerArn" --output text 2>$null)
        $classicElbs = if ($classicElbs) { $classicElbs.Trim() } else { "" }
        $v2Elbs = if ($v2Elbs) { $v2Elbs.Trim() } else { "" }
        if ([string]::IsNullOrEmpty($classicElbs) -and [string]::IsNullOrEmpty($v2Elbs)) { Write-Host "ELB 삭제 완료 확인"; break }
        Write-Host "ELB 삭제 대기 중... ($elapsed s)"
        Start-Sleep -Seconds 10
        $elapsed += 10
      }
      if ($elapsed -ge $timeout) { Write-Host "[WARN] ELB 삭제 타임아웃 — 수동 확인 필요" }
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

  depends_on = [null_resource.service_accounts, null_resource.install_karpenter, null_resource.build_and_push_images]
}

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
# kube-prometheus-stack 설치 (self-hosted Prometheus + Grafana)
# AMP/AMG 없이 클러스터 내부에서 완결 — 비용 $0
# ============================================================
resource "null_resource" "install_prometheus" {
  triggers = {
    cluster_name    = aws_eks_cluster.main.name
    values_hash     = filesha256("${path.module}/../helm/y2ks/prometheus-values.yaml")
    grafana_pw_hash = sha256(var.grafana_admin_password)
  }

  # ── destroy: helm 제거 + 보안그룹 규칙 삭제 ──────────────────
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "SilentlyContinue"
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ap-northeast-2 2>$null

      # pod 강제 종료 먼저 (namespace hang 방지)
      kubectl delete pods --all -n monitoring --force --grace-period=0 2>$null

      # helm uninstall (--no-hooks 로 hook hang 방지)
      helm uninstall prometheus --namespace monitoring --no-hooks --timeout 2m0s 2>$null

      # CRD finalizer 제거 — Prometheus Operator CRD가 finalizer 갖고 있으면 namespace가 Terminating에서 멈춤
      $crdKinds = @("prometheusrules","servicemonitors","podmonitors","alertmanagers","prometheuses","probes","thanosrulers")
      foreach ($kind in $crdKinds) {
        $items = kubectl get $kind -n monitoring --no-headers -o name 2>$null
        foreach ($item in ($items -split "`n" | Where-Object { $_ })) {
          kubectl patch $item -n monitoring --type=merge -p '{"metadata":{"finalizers":[]}}' 2>$null
        }
      }

      # namespace 삭제 (60초 타임아웃, 실패해도 계속)
      $job = Start-Job { kubectl delete namespace monitoring --timeout=60s --ignore-not-found 2>$null }
      Wait-Job $job -Timeout 65 | Out-Null
      Remove-Job $job -Force 2>$null

      # ELB 보안그룹 → 노드 보안그룹 NodePort 규칙 삭제
      $nodeSg = aws ec2 describe-security-groups `
        --filters "Name=tag:kubernetes.io/cluster/${self.triggers.cluster_name},Values=owned" `
                  "Name=group-name,Values=eks-cluster-sg-*" `
        --query "SecurityGroups[0].GroupId" --output text --region ap-northeast-2 2>$null
      if ($nodeSg -and $nodeSg -ne "None") {
        $rules = aws ec2 describe-security-group-rules `
          --filters "Name=group-id,Values=$nodeSg" `
          --query "SecurityGroupRules[?FromPort==``30000`` && IsEgress==``false``].SecurityGroupRuleId" `
          --output text --region ap-northeast-2 2>$null
        if ($rules -and $rules -ne "None") {
          foreach ($rule in ($rules -split "\s+" | Where-Object { $_ })) {
            aws ec2 revoke-security-group-ingress --group-id $nodeSg `
              --security-group-rule-ids $rule --region ap-northeast-2 2>$null
          }
          Write-Host "[OK] 보안그룹 규칙 삭제 완료"
        }
      }
      exit 0
    EOT
  }

  # ── apply: helm 설치 + 보안그룹 규칙 추가 ──────────────────────
  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}

      # ── 1. helm 설치 ─────────────────────────────────────────
      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
      helm repo update

      helm upgrade --install prometheus prometheus-community/kube-prometheus-stack `
        --namespace monitoring --create-namespace `
        -f "${path.module}/../helm/y2ks/prometheus-values.yaml" `
        --set grafana.adminPassword="${var.grafana_admin_password}" `
        --wait --timeout 8m
      if ($LASTEXITCODE -ne 0) { throw "kube-prometheus-stack 설치 실패" }
      Write-Host "[OK] kube-prometheus-stack 설치 완료"

      # ── 2. 보안그룹 규칙: ELB SG → 노드 SG NodePort 허용 ────
      # Grafana LoadBalancer의 ELB SG가 생성될 때까지 폴링 (최대 3분)
      # ELB SG 이름 패턴: k8s-elb-* (Classic LB) 또는 k8s-*-* (NLB/ALB)
      $nodeSg = aws ec2 describe-security-groups `
        --filters "Name=tag:kubernetes.io/cluster/${var.cluster_name},Values=owned" `
                  "Name=group-name,Values=eks-cluster-sg-*" `
        --query "SecurityGroups[0].GroupId" --output text --region ${var.aws_region}

      if (-not $nodeSg -or $nodeSg -eq "None") {
        throw "[ERROR] 노드 보안그룹을 찾을 수 없습니다"
      }
      Write-Host "[OK] 노드 보안그룹: $nodeSg"

      $elbSg = $null
      $elapsed = 0
      $maxWait = 180
      Write-Host "ELB 보안그룹 생성 대기 중..."
      while ($elapsed -lt $maxWait) {
        # Classic LB (k8s-elb-*) 와 NLB/ALB (k8s-*) 패턴 모두 시도
        $elbSg = aws ec2 describe-security-groups `
          --filters "Name=tag:kubernetes.io/cluster/${var.cluster_name},Values=owned" `
                    "Name=group-name,Values=k8s-elb-*" `
          --query "SecurityGroups[0].GroupId" --output text --region ${var.aws_region} 2>$null
        if (-not $elbSg -or $elbSg -eq "None") {
          $elbSg = aws ec2 describe-security-groups `
            --filters "Name=tag:kubernetes.io/cluster/${var.cluster_name},Values=owned" `
                      "Name=tag:kubernetes.io/service-name,Values=monitoring/prometheus-grafana" `
            --query "SecurityGroups[0].GroupId" --output text --region ${var.aws_region} 2>$null
        }
        if ($elbSg -and $elbSg -ne "None") {
          Write-Host "[OK] ELB 보안그룹 발견: $elbSg ($elapsed 초 경과)"
          break
        }
        Start-Sleep -Seconds 10
        $elapsed += 10
        Write-Host "  대기 중... ($elapsed/$maxWait 초)"
      }

      if ($elbSg -and $elbSg -ne "None") {
        $existing = aws ec2 describe-security-group-rules `
          --filters "Name=group-id,Values=$nodeSg" `
          --query "SecurityGroupRules[?FromPort==``30000`` && IsEgress==``false``].SecurityGroupRuleId" `
          --output text --region ${var.aws_region}
        if (-not $existing -or $existing -eq "None") {
          aws ec2 authorize-security-group-ingress `
            --group-id $nodeSg `
            --protocol tcp --port 30000-32767 `
            --source-group $elbSg `
            --region ${var.aws_region} | Out-Null
          Write-Host "[OK] 보안그룹 규칙 추가: $elbSg -> $nodeSg (30000-32767)"
        } else {
          Write-Host "[SKIP] 보안그룹 규칙 이미 존재"
        }
      } else {
        Write-Host "[WARN] ELB 보안그룹을 찾지 못했습니다 — NodePort 규칙 수동 확인 필요"
      }
    EOT
  }

  depends_on = [null_resource.kubeconfig]
}

# ============================================================
# ServiceMonitor + Grafana 대시보드 ConfigMap 적용
# KEDA, Karpenter 설치 완료 후 실행해야 namespace가 존재함
# ============================================================
resource "null_resource" "apply_monitoring_manifests" {
  triggers = {
    cluster_name = aws_eks_cluster.main.name
    values_hash  = filesha256("${path.module}/../helm/y2ks/prometheus-values.yaml")
    dashboards_hash = sha256(join("", [
      filesha256("${path.module}/../helm/y2ks/dashboards/keda.json"),
      filesha256("${path.module}/../helm/y2ks/dashboards/karpenter.json"),
      filesha256("${path.module}/../helm/y2ks/dashboards/k6.json"),
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}

      $dashboardsDir = "${path.module}/../helm/y2ks/dashboards"

      # ── 대시보드 ConfigMap 생성 (JSON 파일을 직접 읽어서 적용) ──
      foreach ($name in @("keda", "karpenter", "k6")) {
        $jsonContent = Get-Content "$dashboardsDir/$name.json" -Raw -Encoding UTF8
        $cm = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-$name
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  $name.json: |
$(($jsonContent -split "`n" | ForEach-Object { "    $_" }) -join "`n")
"@
        $f = [System.IO.Path]::GetTempFileName() + ".yaml"
        [System.IO.File]::WriteAllText($f, $cm, [System.Text.Encoding]::UTF8)
        kubectl apply -f $f
        Remove-Item $f -ErrorAction SilentlyContinue
        Write-Host "[OK] ConfigMap grafana-dashboard-$name 적용"
      }

      # ── ServiceMonitor 적용 ──────────────────────────────────
      $sm = @'
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: keda-operator
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: keda-operator
  namespaceSelector:
    matchNames:
      - keda
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: karpenter
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: karpenter
  namespaceSelector:
    matchNames:
      - karpenter
  endpoints:
    - port: http-metrics
      interval: 30s
      path: /metrics
'@
      $f = [System.IO.Path]::GetTempFileName() + ".yaml"
      [System.IO.File]::WriteAllText($f, $sm, [System.Text.Encoding]::UTF8)
      kubectl apply -f $f
      Remove-Item $f -ErrorAction SilentlyContinue
      Write-Host "[OK] ServiceMonitor 적용 완료"
    EOT
  }

  # KEDA, Karpenter namespace가 존재한 후 실행
  depends_on = [
    null_resource.install_prometheus,
    null_resource.install_keda,
    null_resource.install_karpenter,
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
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "SilentlyContinue"
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ap-northeast-2 2>$null
      # ScaledObject finalizer 제거 — finalizer 있으면 helm uninstall이 hung 상태로 대기
      $scaled = kubectl get scaledobjects --all-namespaces --no-headers -o name 2>$null
      foreach ($s in ($scaled -split "`n" | Where-Object { $_ })) {
        kubectl patch $s --type=merge -p '{"metadata":{"finalizers":[]}}' 2>$null
      }
      helm uninstall keda --namespace keda --timeout 2m0s 2>$null
      exit 0
    EOT
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.aws_region}

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
      # Public ECR — 인증 없이 pull 가능 (퍼블릭 레포)
      Remove-Item "$env:APPDATA\helm\registry\config.json" -ErrorAction SilentlyContinue

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
    admin_token_hash    = sha256(var.admin_token)
    grafana_pw_hash     = sha256(var.grafana_admin_password)
    # 템플릿 파일 변경 감지 → terraform apply 시 자동 재배포
    config_hash = sha256(join("", [
      file("${path.module}/../helm/y2ks/templates/aws-config.yaml"),
      file("${path.module}/../helm/y2ks/templates/aws-secret.yaml"),
      file("${path.module}/../helm/y2ks/templates/frontend.yaml"),
      file("${path.module}/../helm/y2ks/templates/worker.yaml"),
      file("${path.module}/../helm/y2ks/templates/keda.yaml"),
      file("${path.module}/../helm/y2ks/templates/agent.yaml"),
      file("${path.module}/../helm/y2ks/templates/configmap-code.yaml"),
      file("${path.module}/../helm/y2ks/templates/configmap-k6.yaml"),
    ]))
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "SilentlyContinue"
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ap-northeast-2 2>$null

      Write-Host "=== [pre] Karpenter/LB 사전 정리 (apply-replace/destroy 공통) ==="
      # worker 스케일다운 → Karpenter가 새 노드 프로비저닝하는 것 방지
      kubectl scale deployment y2ks-worker --replicas=0 -n default 2>$null
      # Karpenter NodeClaim finalizer 제거 → finalizer가 걸린 채로 delete하면 무한 hang
      $nodeclaims = kubectl get nodeclaims --no-headers -o name 2>$null
      foreach ($nc in ($nodeclaims -split "`n" | Where-Object { $_ })) {
        $ncName = $nc -replace "nodeclaim.karpenter.sh/", ""
        kubectl patch nodeclaim $ncName --type=merge -p '{"metadata":{"finalizers":[]}}' 2>$null
      }
      # Karpenter NodeClaim/NodePool 삭제 → Karpenter 관리 노드 제거 트리거
      kubectl delete nodeclaims --all --timeout=30s 2>$null
      kubectl delete nodepool --all --timeout=30s 2>$null
      # LB 서비스 삭제 → AWS ELB 즉시 제거 (VPC 삭제 블로킹 방지)
      kubectl delete svc y2ks-frontend-svc -n default 2>$null
      kubectl delete svc prometheus-grafana -n monitoring 2>$null
      # Karpenter EC2 인스턴스 완전 종료 대기 (최대 2분)
      $elapsed = 0
      while ($elapsed -lt 120) {
        $count = aws ec2 describe-instances `
          --filters "Name=tag:karpenter.sh/nodepool,Values=*" `
                    "Name=instance-state-name,Values=pending,running,stopping" `
          --query "length(Reservations[].Instances[])" --output text --region ap-northeast-2 2>$null
        if (-not $count -or $count -eq "0") { Write-Host "[OK] Karpenter 노드 종료 완료 ($elapsed s)"; break }
        Write-Host "Karpenter 노드 $count 개 종료 대기... ($elapsed s)"
        Start-Sleep -Seconds 10; $elapsed += 10
      }

      # terraform apply -replace 감지: y2ks Helm release가 살아있으면 apply replace이므로
      # helm uninstall 이후 단계는 건너뜀 (create provisioner가 재배포함)
      helm status y2ks --namespace default 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "[SKIP] y2ks Helm release 존재 — terraform apply replace 감지, helm uninstall 건너뜀"
        exit 0
      }
      Write-Host "y2ks Helm release 없음 — terraform destroy 진행"

      Write-Host "=== [0/4] EKS Cluster SG 인바운드/아웃바운드 규칙 사전 정리 ==="
      # EKS가 자동 생성한 cluster SG의 규칙을 미리 제거해 VPC 삭제 블로킹 방지
      $clusterSg = aws ec2 describe-security-groups `
        --filters "Name=tag:kubernetes.io/cluster/${self.triggers.cluster_name},Values=owned" `
                  "Name=group-name,Values=eks-cluster-sg-*" `
        --query "SecurityGroups[0].GroupId" --output text --region ap-northeast-2 2>$null
      if ($clusterSg -and $clusterSg -ne "None") {
        $ingressRules = aws ec2 describe-security-group-rules `
          --filters "Name=group-id,Values=$clusterSg" `
          --query "SecurityGroupRules[?IsEgress==``false``].SecurityGroupRuleId" `
          --output text --region ap-northeast-2 2>$null
        if ($ingressRules -and $ingressRules -ne "None") {
          $ruleIds = $ingressRules -split "\s+" | Where-Object { $_ }
          aws ec2 revoke-security-group-ingress --group-id $clusterSg `
            --security-group-rule-ids $ruleIds --region ap-northeast-2 2>$null
        }
        $egressRules = aws ec2 describe-security-group-rules `
          --filters "Name=group-id,Values=$clusterSg" `
          --query "SecurityGroupRules[?IsEgress==``true``].SecurityGroupRuleId" `
          --output text --region ap-northeast-2 2>$null
        if ($egressRules -and $egressRules -ne "None") {
          $ruleIds = $egressRules -split "\s+" | Where-Object { $_ }
          aws ec2 revoke-security-group-egress --group-id $clusterSg `
            --security-group-rule-ids $ruleIds --region ap-northeast-2 2>$null
        }
        Write-Host "[OK] Cluster SG 규칙 정리: $clusterSg"
      } else {
        Write-Host "Cluster SG 없음 — 건너뜀"
      }

      # ── [병목1 fix] 관리형 노드그룹 사전 drain + scale-down ──────
      # Terraform이 노드그룹을 삭제할 때 직접 drain하면 오래 걸림
      # 미리 drain + desired=0 으로 줄여두면 Terraform 삭제가 수 분 단축됨
      Write-Host "=== [1a/4] 관리형 노드그룹 drain + scale-down ==="
      $managedNodeGroups = @("ondemand-1", "ondemand-2")
      foreach ($ng in $managedNodeGroups) {
        $nodes = kubectl get nodes -l "node-type=$ng" --no-headers -o name 2>$null
        if ($nodes) {
          foreach ($node in ($nodes -split "`n" | Where-Object { $_ })) {
            Write-Host "drain: $node"
            kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>$null
          }
        }
        aws eks update-nodegroup-config `
          --cluster-name ${self.triggers.cluster_name} `
          --nodegroup-name $ng `
          --scaling-config minSize=0,maxSize=2,desiredSize=0 `
          --region ap-northeast-2 2>$null
        Write-Host "[OK] $ng scale-down 요청 완료"
      }

      Write-Host "=== [1b/4] Karpenter 노드 drain + EC2 직접 종료 ==="
      $karpenterNodes = kubectl get nodes -l karpenter.sh/nodepool --no-headers -o name 2>$null
      if ($karpenterNodes) {
        foreach ($node in ($karpenterNodes -split "`n" | Where-Object { $_ })) {
          Write-Host "노드 drain: $node"
          kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --timeout=90s 2>$null
          kubectl delete $node --timeout=30s 2>$null
        }
      } else {
        Write-Host "Karpenter 노드 없음 — drain 건너뜀"
      }

      # ASG --force-delete 후 EC2 인스턴스도 직접 terminate (병목1 fix)
      $asgs = aws autoscaling describe-auto-scaling-groups `
        --query "AutoScalingGroups[?not_null(Tags[?Key=='karpenter.sh/nodepool'])].AutoScalingGroupName" `
        --output text 2>$null
      if ($asgs) {
        foreach ($asg in ($asgs -split "\s+" | Where-Object { $_ })) {
          Write-Host "ASG 삭제 중: $asg"
          aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $asg --force-delete 2>$null
        }
        # ASG --force-delete와 병행하여 EC2 인스턴스 직접 종료 → 폴링 시간 단축
        $instanceIds = aws ec2 describe-instances `
          --filters "Name=tag:karpenter.sh/nodepool,Values=*" `
                    "Name=instance-state-name,Values=pending,running,stopping" `
          --query "Reservations[].Instances[].InstanceId" --output text 2>$null
        if ($instanceIds -and $instanceIds -ne "None") {
          Write-Host "EC2 인스턴스 직접 종료: $instanceIds"
          aws ec2 terminate-instances --instance-ids ($instanceIds -split "\s+" | Where-Object { $_ }) `
            --region ap-northeast-2 2>$null
        }
        Write-Host "EC2 terminate 완료까지 폴링 (최대 3분)..."
        $maxWait = 180
        $elapsed = 0
        while ($elapsed -lt $maxWait) {
          $runningCount = aws ec2 describe-instances `
            --filters "Name=tag:karpenter.sh/nodepool,Values=*" `
                      "Name=instance-state-name,Values=pending,running,stopping" `
            --query "length(Reservations[].Instances[])" --output text 2>$null
          if (-not $runningCount -or $runningCount -eq "0") {
            Write-Host "[OK] 모든 Karpenter 노드 종료 완료 ($elapsed s)"; break
          }
          Write-Host "Karpenter 노드 $runningCount 개 종료 대기... ($elapsed s)"
          Start-Sleep -Seconds 10
          $elapsed += 10
        }
        if ($elapsed -ge $maxWait) { Write-Host "[WARN] Karpenter EC2 종료 타임아웃 — 수동 확인 필요" }
      } else {
        Write-Host "Karpenter ASG 없음 — 건너뜀"
      }

      Write-Host "=== [2/4] Y2KS 앱 삭제 + ELB 직접 삭제 (병목2 fix) ==="
      helm uninstall y2ks --namespace default --timeout 2m0s 2>$null

      # K8s 컨트롤러가 ELB를 알아서 삭제하길 기다리는 대신 AWS CLI로 직접 삭제
      $vpcId = aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${self.triggers.cluster_name}-vpc" --query "Vpcs[0].VpcId" --output text 2>$null
      if ($vpcId -and $vpcId -ne "None") {
        # Classic ELB 직접 삭제
        $classicElbs = aws elb describe-load-balancers `
          --query "LoadBalancerDescriptions[?VPCId=='$vpcId'].LoadBalancerName" `
          --output text 2>$null
        foreach ($elb in ($classicElbs -split "\s+" | Where-Object { $_ })) {
          Write-Host "Classic ELB 삭제: $elb"
          aws elb delete-load-balancer --load-balancer-name $elb 2>$null
        }
        # ALB/NLB 직접 삭제
        $v2Elbs = aws elbv2 describe-load-balancers `
          --query "LoadBalancers[?VpcId=='$vpcId'].LoadBalancerArn" `
          --output text 2>$null
        foreach ($elb in ($v2Elbs -split "\s+" | Where-Object { $_ })) {
          Write-Host "ALB/NLB 삭제: $elb"
          aws elbv2 delete-load-balancer --load-balancer-arn $elb 2>$null
        }
        # ELB 삭제 완료 확인 (최대 2분으로 단축)
        $timeout = 120
        $elapsed = 0
        while ($elapsed -lt $timeout) {
          $remaining = @(
            (aws elb describe-load-balancers --query "LoadBalancerDescriptions[?VPCId=='$vpcId'].LoadBalancerName" --output text 2>$null),
            (aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$vpcId'].LoadBalancerArn" --output text 2>$null)
          ) | Where-Object { $_ -and $_.Trim() -ne "" }
          if ($remaining.Count -eq 0) { Write-Host "[OK] ELB 삭제 완료 ($elapsed s)"; break }
          Start-Sleep -Seconds 10; $elapsed += 10
        }
        if ($elapsed -ge $timeout) { Write-Host "[WARN] ELB 삭제 타임아웃" }
      }

      Write-Host "=== [3/4] 잔존 ENI 정리 ==="
      if ($vpcId -and $vpcId -ne "None") {
        # available 상태 ENI 직접 삭제 (VPC 삭제 블로킹 방지)
        $availableEnis = aws ec2 describe-network-interfaces `
          --filters "Name=vpc-id,Values=$vpcId" "Name=status,Values=available" `
          --query "NetworkInterfaces[*].NetworkInterfaceId" --output text 2>$null
        foreach ($eni in ($availableEnis -split "\s+" | Where-Object { $_ })) {
          Write-Host "ENI 삭제: $eni"
          aws ec2 delete-network-interface --network-interface-id $eni 2>$null
        }
        $inUseEnis = aws ec2 describe-network-interfaces `
          --filters "Name=vpc-id,Values=$vpcId" "Name=status,Values=in-use" `
          --query "NetworkInterfaces[*].NetworkInterfaceId" --output text 2>$null
        if ($inUseEnis -and $inUseEnis -ne "None") {
          Write-Host "[WARN] in-use ENI 남아있음 (ELB/NAT가 아직 정리 중): $inUseEnis"
        } else {
          Write-Host "[OK] 잔존 ENI 없음"
        }
      }

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
        --set-string accountId=${data.aws_caller_identity.current.account_id} `
        --set region=${var.aws_region} `
        --set clusterName=${var.cluster_name} `
        --set workerRoleArn=${aws_iam_role.worker.arn} `
        --set agentRoleArn=${aws_iam_role.agent.arn} `
        --set karpenterNodeRoleName=${aws_iam_role.karpenter_node.name} `
        --set images.frontend=${aws_ecr_repository.frontend.repository_url}:latest `
        --set images.worker=${aws_ecr_repository.worker.repository_url}:latest `
        --set images.agent=${aws_ecr_repository.agent.repository_url}:latest `
        --set adminToken="${var.admin_token}" `
        --set grafanaPassword="${var.grafana_admin_password}"
    EOT
  }

  depends_on = [null_resource.service_accounts, null_resource.install_karpenter, null_resource.build_and_push_images, null_resource.apply_monitoring_manifests]
}

# ============================================================
# Route53 DNS — y2ks-frontend-svc ELB → 도메인 연결
# ============================================================
resource "null_resource" "setup_dns" {
  depends_on = [null_resource.install_y2ks]

  triggers = {
    cluster_name   = var.cluster_name
    domain_name    = var.domain_name
    hosted_zone_id = data.aws_route53_zone.main.zone_id
  }

  # apply: ELB hostname → Route53 A alias 레코드 생성/갱신
  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      aws eks update-kubeconfig --name ${var.cluster_name} --region ap-northeast-2 2>$null

      Write-Host "=== Route53 DNS 설정 ==="

      # ELB EXTERNAL-IP 대기 (최대 5분)
      $elbHostname = $null
      for ($i = 0; $i -lt 30; $i++) {
        $elbHostname = kubectl get svc y2ks-frontend-svc `
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
        if ($elbHostname) { break }
        Write-Host "  ELB 대기중... ($i/30)"
        Start-Sleep -Seconds 10
      }
      if (-not $elbHostname) { Write-Error "ELB EXTERNAL-IP 획득 실패"; exit 1 }
      Write-Host "  ELB hostname: $elbHostname"

      # Classic ELB canonical hosted zone ID 조회 (DNS name으로 검색 — 이름 파싱 불필요)
      # ELB DNS 형식: <hash>-<number>.<region>.elb.amazonaws.com
      # --load-balancer-names 는 hash 부분만 필요하나 파싱이 불안정 → DNSName contains 로 조회
      $ErrorActionPreference = "SilentlyContinue"
      $elbHostnamePrefix = $elbHostname.Split('.')[0]
      $elbZoneId = aws elb describe-load-balancers `
        --query "LoadBalancerDescriptions[?contains(DNSName, '$elbHostnamePrefix')].CanonicalHostedZoneNameID | [0]" `
        --output text 2>$null
      $ErrorActionPreference = "Stop"
      Write-Host "  ELB hosted zone ID: $elbZoneId"

      # [1] y2ks.site → 프론트엔드 ELB (임시 파일로 JSON 전달 — PowerShell ConvertTo-Json 따옴표 버그 방지)
      $tmpJson = "$env:TEMP\r53-frontend.json"
      $jsonStr = '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"${var.domain_name}.","Type":"A","AliasTarget":{"HostedZoneId":"' + $elbZoneId + '","DNSName":"dualstack.' + $elbHostname + '.","EvaluateTargetHealth":false}}}]}'
      [System.IO.File]::WriteAllText($tmpJson, $jsonStr)
      aws route53 change-resource-record-sets `
        --hosted-zone-id ${data.aws_route53_zone.main.zone_id} `
        --change-batch "file://$tmpJson"
      if ($LASTEXITCODE -ne 0) { Remove-Item $tmpJson -Force; Write-Error "Route53 프론트엔드 레코드 생성 실패"; exit 1 }
      Remove-Item $tmpJson -Force
      Write-Host "[OK] ${var.domain_name} → $elbHostname"

      # [2] grafana.y2ks.site → Grafana ELB
      $ErrorActionPreference = "SilentlyContinue"
      $grafanaHostname = kubectl get svc prometheus-grafana -n monitoring `
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
      if ($grafanaHostname) {
        $grafanaPrefix = $grafanaHostname.Split('.')[0]
        $grafanaZoneId = aws elb describe-load-balancers `
          --query "LoadBalancerDescriptions[?contains(DNSName, '$grafanaPrefix')].CanonicalHostedZoneNameID | [0]" `
          --output text 2>$null
        $tmpGrafana = "$env:TEMP\r53-grafana.json"
        $grafanaJson = '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"grafana.${var.domain_name}.","Type":"A","AliasTarget":{"HostedZoneId":"' + $grafanaZoneId + '","DNSName":"dualstack.' + $grafanaHostname + '.","EvaluateTargetHealth":false}}}]}'
        [System.IO.File]::WriteAllText($tmpGrafana, $grafanaJson)
        aws route53 change-resource-record-sets `
          --hosted-zone-id ${data.aws_route53_zone.main.zone_id} `
          --change-batch "file://$tmpGrafana" 2>$null
        Remove-Item $tmpGrafana -Force
        Write-Host "[OK] grafana.${var.domain_name} → $grafanaHostname"
      } else {
        Write-Host "[WARN] Grafana ELB hostname 조회 실패 — DNS 설정 건너뜀"
      }
      $ErrorActionPreference = "Stop"
      Write-Host "=== Route53 DNS 설정 완료 ==="
    EOT
  }

  # destroy: Route53 A 레코드 삭제 (임시 파일 방식으로 JSON 전달)
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "SilentlyContinue"
      Write-Host "=== Route53 레코드 삭제 ==="

      foreach ($recordName in @("${self.triggers.domain_name}.", "grafana.${self.triggers.domain_name}.")) {
        $rec = aws route53 list-resource-record-sets `
          --hosted-zone-id ${self.triggers.hosted_zone_id} `
          --query "ResourceRecordSets[?Name=='$recordName']|[?Type=='A']|[0]" `
          --output json 2>$null | ConvertFrom-Json
        if (-not $rec) { Write-Host "  삭제할 레코드 없음: $recordName"; continue }
        $recJson = $rec | ConvertTo-Json -Depth 10 -Compress
        $delStr = '{"Changes":[{"Action":"DELETE","ResourceRecordSet":' + $recJson + '}]}'
        $tmpDel = "$env:TEMP\r53-delete.json"
        [System.IO.File]::WriteAllText($tmpDel, $delStr)
        aws route53 change-resource-record-sets `
          --hosted-zone-id ${self.triggers.hosted_zone_id} `
          --change-batch "file://$tmpDel" 2>$null
        Remove-Item $tmpDel -Force
        Write-Host "  [OK] $recordName 레코드 삭제 완료"
      }
    EOT
  }
}

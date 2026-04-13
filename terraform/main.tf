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
    cluster_name = aws_eks_cluster.main.name
    values_hash  = filesha256("${path.module}/../helm/y2ks/prometheus-values.yaml")
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

  # ── apply: helm 설치 + 보안그룹 규칙 추가 + ServiceMonitor/대시보드 ──
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
      # ELB 보안그룹 ID (k8s-elb-* 패턴, prometheus-grafana LoadBalancer용)
      Start-Sleep -Seconds 15  # ELB SG 생성 대기
      $elbSg = aws ec2 describe-security-groups `
        --filters "Name=tag:kubernetes.io/cluster/${var.cluster_name},Values=owned" `
                  "Name=group-name,Values=k8s-elb-*" `
        --query "SecurityGroups[0].GroupId" --output text --region ${var.aws_region}

      # 노드 보안그룹 ID (eks-cluster-sg-* 패턴)
      $nodeSg = aws ec2 describe-security-groups `
        --filters "Name=tag:kubernetes.io/cluster/${var.cluster_name},Values=owned" `
                  "Name=group-name,Values=eks-cluster-sg-*" `
        --query "SecurityGroups[0].GroupId" --output text --region ${var.aws_region}

      if ($elbSg -and $elbSg -ne "None" -and $nodeSg -and $nodeSg -ne "None") {
        # 이미 존재하는 규칙인지 확인
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
        Write-Host "[WARN] 보안그룹 자동 설정 실패 — ELB SG: $elbSg, Node SG: $nodeSg"
      }

      # ── 3. ServiceMonitor + 대시보드 ConfigMap ───────────────
      $manifests = @"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-keda
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  keda.json: |
    {"title":"KEDA ScaledObject","uid":"keda-y2ks","schemaVersion":36,"panels":[{"type":"timeseries","title":"Worker Replica Count","gridPos":{"x":0,"y":0,"w":12,"h":8},"targets":[{"expr":"keda_scaler_metrics_value{scaledObject=\"sqs-scaledobject\"}","legendFormat":"SQS Queue Depth"},{"expr":"kube_deployment_status_replicas{deployment=\"y2ks-worker\"}","legendFormat":"Worker Replicas"}]},{"type":"stat","title":"Current Worker Replicas","gridPos":{"x":12,"y":0,"w":6,"h":4},"targets":[{"expr":"kube_deployment_status_replicas{deployment=\"y2ks-worker\"}"}]},{"type":"stat","title":"SQS Queue Depth","gridPos":{"x":18,"y":0,"w":6,"h":4},"targets":[{"expr":"keda_scaler_metrics_value{scaledObject=\"sqs-scaledobject\"}"}]}],"time":{"from":"now-1h","to":"now"},"refresh":"30s"}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-karpenter
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  karpenter.json: |
    {"title":"Karpenter Node Provisioning","uid":"karpenter-y2ks","schemaVersion":36,"panels":[{"type":"timeseries","title":"Nodes Provisioned","gridPos":{"x":0,"y":0,"w":12,"h":8},"targets":[{"expr":"karpenter_nodes_total","legendFormat":"Total Nodes"},{"expr":"karpenter_nodes_allocatable{resource=\"cpu\"}","legendFormat":"Allocatable CPU"}]},{"type":"timeseries","title":"Pod Scheduling Latency","gridPos":{"x":12,"y":0,"w":12,"h":8},"targets":[{"expr":"histogram_quantile(0.99, sum(rate(karpenter_pods_startup_duration_seconds_bucket[5m])) by (le))","legendFormat":"p99"},{"expr":"histogram_quantile(0.50, sum(rate(karpenter_pods_startup_duration_seconds_bucket[5m])) by (le))","legendFormat":"p50"}]}],"time":{"from":"now-1h","to":"now"},"refresh":"30s"}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-k6
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  k6.json: |
    {"title":"k6 Load Test","uid":"k6-y2ks","schemaVersion":36,"panels":[{"type":"timeseries","title":"HTTP Request Rate","gridPos":{"x":0,"y":0,"w":12,"h":8},"targets":[{"expr":"sum(rate(k6_http_reqs_total[1m]))","legendFormat":"req/s"}]},{"type":"timeseries","title":"Response Duration p95","gridPos":{"x":12,"y":0,"w":12,"h":8},"targets":[{"expr":"histogram_quantile(0.95, sum(rate(k6_http_req_duration_seconds_bucket[1m])) by (le))","legendFormat":"p95"},{"expr":"histogram_quantile(0.50, sum(rate(k6_http_req_duration_seconds_bucket[1m])) by (le))","legendFormat":"p50"}]},{"type":"stat","title":"Active VUs","gridPos":{"x":0,"y":8,"w":8,"h":4},"targets":[{"expr":"k6_vus"}]}],"time":{"from":"now-1h","to":"now"},"refresh":"10s"}
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
"@
      $f = [System.IO.Path]::GetTempFileName() + ".yaml"
      [System.IO.File]::WriteAllText($f, $manifests, [System.Text.Encoding]::UTF8)
      kubectl apply -f $f
      Remove-Item $f -ErrorAction SilentlyContinue
      Write-Host "[OK] ServiceMonitor + 대시보드 ConfigMap 적용 완료"
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

  depends_on = [null_resource.service_accounts, null_resource.install_karpenter, null_resource.build_and_push_images, null_resource.install_prometheus]
}

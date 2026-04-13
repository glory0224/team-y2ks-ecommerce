# ============================================================
# Amazon Managed Prometheus (AMP) workspace
# ============================================================
resource "aws_prometheus_workspace" "main" {
  alias = var.amp_workspace_alias

  tags = {
    Project = "y2ks"
  }
}

# ============================================================
# Prometheus remote_write용 IRSA
# prometheus-kube-prometheus-prometheus SA에 연결
# ============================================================
resource "aws_iam_role" "amp_ingest" {
  name = "Y2ksAMPIngestRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${local.account_id}:oidc-provider/${local.oidc_issuer}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:monitoring:prometheus-kube-prometheus-prometheus"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "amp_ingest" {
  name = "AMPIngestPolicy"
  role = aws_iam_role.amp_ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ]
      Resource = aws_prometheus_workspace.main.arn
    }]
  })
}

# ============================================================
# kube-prometheus-stack + KEDA Prometheus metrics 설정
#
# 매 apply마다 실행 (always_run = timestamp())
# helm upgrade --install은 멱등성 보장:
#   - 없으면 install, 있으면 upgrade, 상태 동일하면 no-op
#
# KEDA Prometheus metrics 활성화:
#   - --enable-prometheus-metrics=true (port 8080)
#   - terraform/main.tf의 install_keda는 기본값으로 설치하므로
#     monitoring apply 시 여기서 upgrade하여 metrics 활성화 보장
#
# ServiceMonitor 포트 (디버깅으로 확인된 실제 포트명):
#   - keda-operator: metrics (8080) — prometheus metrics HTTP 엔드포인트
#   - karpenter:     http-metrics (8080)
# ============================================================
resource "null_resource" "prometheus_stack" {
  triggers = {
    always_run   = timestamp()
    amp_endpoint = aws_prometheus_workspace.main.prometheus_endpoint
    role_arn     = aws_iam_role.amp_ingest.arn
    values_hash  = filesha256("${path.module}/prometheus-values.yaml")
    cluster_name = var.cluster_name
    region       = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}

      # ── 1. kube-prometheus-stack ──────────────────────────────────────
      $values = Get-Content "${path.module}/prometheus-values.yaml" -Raw
      $values = $values -replace "__AMP_ROLE_ARN__", "${aws_iam_role.amp_ingest.arn}"
      $values = $values -replace "__AMP_ENDPOINT__", "${aws_prometheus_workspace.main.prometheus_endpoint}"
      $tmpFile = [System.IO.Path]::GetTempFileName() + ".yaml"
      $values | Set-Content $tmpFile -Encoding UTF8

      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
      helm repo update

      helm upgrade --install prometheus prometheus-community/kube-prometheus-stack `
        --namespace monitoring --create-namespace `
        --set prometheusOperator.admissionWebhooks.enabled=false `
        --set prometheusOperator.admissionWebhooks.patch.enabled=false `
        --set prometheusOperator.tls.enabled=false `
        -f $tmpFile
      if ($LASTEXITCODE -ne 0) {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        throw "kube-prometheus-stack 설치 실패 (exit $LASTEXITCODE)"
      }
      Remove-Item $tmpFile
      Write-Host "[OK] kube-prometheus-stack"

      # ── 2. KEDA Prometheus metrics 활성화 ────────────────────────────
      # keda 네임스페이스가 없으면(클러스터 재생성 직후) 건너뜀
      $kedaNs = kubectl get namespace keda --ignore-not-found 2>$null
      if ($kedaNs) {
        helm repo add kedacore https://kedacore.github.io/charts
        helm repo update
        helm upgrade keda kedacore/keda `
          --namespace keda `
          --reuse-values `
          --set prometheus.operator.enabled=true `
          --set prometheus.operator.port=8080 `
          --set prometheus.metricServer.enabled=true `
          --set prometheus.metricServer.port=9022
        if ($LASTEXITCODE -ne 0) { throw "KEDA prometheus metrics 활성화 실패 (exit $LASTEXITCODE)" }

        # IRSA 토큰 갱신을 위해 keda-operator 재시작 후 대기
        kubectl rollout restart deployment/keda-operator -n keda
        kubectl rollout status deployment/keda-operator -n keda --timeout=120s
        Write-Host "[OK] KEDA prometheus metrics 활성화"
      } else {
        Write-Host "[SKIP] keda 네임스페이스 없음 — terraform/main.tf apply 후 재실행 필요"
      }

      # ── 3. ServiceMonitor 적용 ────────────────────────────────────────
      $sm = @"
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
      $smFile = [System.IO.Path]::GetTempFileName() + ".yaml"
      [System.IO.File]::WriteAllText($smFile, $sm, [System.Text.Encoding]::UTF8)
      kubectl apply -f $smFile
      if ($LASTEXITCODE -ne 0) {
        Remove-Item $smFile -ErrorAction SilentlyContinue
        throw "ServiceMonitor 적용 실패"
      }
      Remove-Item $smFile
      Write-Host "[OK] ServiceMonitor 적용 완료"

      Write-Host "=== prometheus_stack 완료 ==="

      # ── 4. k6 ampEndpoint ConfigMap 생성/업데이트 ────────────────────
      $ampEndpoint = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
      $ampWorkspaceId = "${aws_prometheus_workspace.main.id}"
      $cm = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: y2ks-k6-config
  namespace: default
data:
  ampEndpoint: "$ampEndpoint"
  ampWorkspaceId: "$ampWorkspaceId"
"@
      $cmFile = [System.IO.Path]::GetTempFileName() + ".yaml"
      [System.IO.File]::WriteAllText($cmFile, $cm, [System.Text.Encoding]::UTF8)
      kubectl apply -f $cmFile
      if ($LASTEXITCODE -ne 0) {
        Remove-Item $cmFile -ErrorAction SilentlyContinue
        throw "y2ks-k6-config ConfigMap 적용 실패 (exit $LASTEXITCODE)"
      }
      Remove-Item $cmFile
      Write-Host "[OK] y2ks-k6-config ConfigMap 적용 완료"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} 2>$null

      # k6 ConfigMap 삭제 — stdout 모드로 자동 fallback
      kubectl delete configmap y2ks-k6-config --ignore-not-found
      Write-Host "[OK] y2ks-k6-config ConfigMap 삭제 완료"

      # prometheus-stack 제거
      helm uninstall prometheus -n monitoring --ignore-not-found 2>&1
      Write-Host "[OK] prometheus uninstall 완료"
    EOT
  }

  depends_on = [
    aws_prometheus_workspace.main,
    aws_iam_role_policy.amp_ingest
  ]
}

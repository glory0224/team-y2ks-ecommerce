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
# kube-prometheus-stack 설치
# - AMP remote_write (IRSA SigV4, roleArn 불필요)
# - KEDA ServiceMonitor (port: metricsservice/9666, label: app.kubernetes.io/name: keda-operator)
# - Karpenter ServiceMonitor (port: http-metrics/8080, label: app.kubernetes.io/name: karpenter)
# - serviceMonitorSelector: {} → 모든 네임스페이스 ServiceMonitor 수집
#
# 다음에 재설치할 때: terraform apply 한 번으로 전부 반영됨
# ============================================================
resource "null_resource" "prometheus_stack" {
  triggers = {
    amp_endpoint = aws_prometheus_workspace.main.prometheus_endpoint
    role_arn     = aws_iam_role.amp_ingest.arn
    values_hash  = filesha256("${path.module}/prometheus-values.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region}

      # values 파일의 플레이스홀더를 실제 값으로 치환
      $values = Get-Content "${path.module}/prometheus-values.yaml" -Raw
      $values = $values -replace "__AMP_ROLE_ARN__", "${aws_iam_role.amp_ingest.arn}"
      $values = $values -replace "__AMP_ENDPOINT__", "${aws_prometheus_workspace.main.prometheus_endpoint}"
      $tmpFile = [System.IO.Path]::GetTempFileName() + ".yaml"
      [System.IO.File]::WriteAllText($tmpFile, $values, (New-Object System.Text.UTF8Encoding $false))

      helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
      helm repo update

      helm upgrade --install prometheus prometheus-community/kube-prometheus-stack `
        --namespace monitoring --create-namespace `
        -f $tmpFile

      Remove-Item $tmpFile

      Write-Host "kube-prometheus-stack 설치 완료"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = "helm uninstall prometheus -n monitoring --ignore-not-found 2>&1; Write-Host done"
  }

  depends_on = [
    aws_prometheus_workspace.main,
    aws_iam_role_policy.amp_ingest
  ]
}

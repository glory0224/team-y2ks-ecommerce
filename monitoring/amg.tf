# ============================================================
# Amazon Managed Grafana (AMG) workspace
# IAM Identity Center(SSO) 인증 사용
# ============================================================

# destroy 후 재생성 시 AWS가 workspace를 완전히 삭제할 때까지 대기
# (같은 이름으로 바로 생성하면 409 ConflictException 발생)
resource "null_resource" "wait_amg_deleted" {
  triggers = {
    workspace_name = var.amg_workspace_name
    region         = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $name   = "${var.amg_workspace_name}"
      $region = "${var.aws_region}"
      $max    = 30
      for ($i = 0; $i -lt $max; $i++) {
        $existing = aws grafana list-workspaces --region $region --output json |
          ConvertFrom-Json | Select-Object -ExpandProperty workspaces |
          Where-Object { $_.name -eq $name -and $_.status -ne "DELETING" }
        if (-not $existing) { Write-Host "workspace cleared"; break }
        Write-Host "waiting for workspace deletion... ($($i*10)s)"
        Start-Sleep -Seconds 10
      }
    EOT
  }
}

resource "aws_grafana_workspace" "main" {
  name                     = var.amg_workspace_name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.amg.arn

  data_sources = ["PROMETHEUS"]

  tags = {
    Project = "y2ks"
  }

  depends_on = [null_resource.wait_amg_deleted]
}

# ============================================================
# AMG IAM Role - AMP 쿼리 권한
# ============================================================
resource "aws_iam_role" "amg" {
  name = "Y2ksAMGRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "grafana.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
        StringLike = {
          "aws:SourceArn" = "arn:aws:grafana:${var.aws_region}:${local.account_id}:/workspaces/*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "amg_amp_query" {
  name = "AMGAMPQueryPolicy"
  role = aws_iam_role.amg.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata",
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "arn:aws:sns:${var.aws_region}:${local.account_id}:*"
      }
    ]
  })
}

# ============================================================
# AMG에 AMP datasource 연결
# - upsert 방식: 이미 존재하면 PUT으로 업데이트, 없으면 POST로 생성
# - destroy 시 삭제
# ============================================================
resource "null_resource" "amg_datasource" {
  triggers = {
    workspace_id = aws_grafana_workspace.main.id
    amp_endpoint = aws_prometheus_workspace.main.prometheus_endpoint
    region       = var.aws_region
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $workspaceId = "${aws_grafana_workspace.main.id}"
      $region = "${var.aws_region}"
      $grafanaUrl = "https://$workspaceId.grafana-workspace.$region.amazonaws.com"
      $ampUrl = "${aws_prometheus_workspace.main.prometheus_endpoint}".TrimEnd('/')

      # API key - 타임스탬프로 충돌 방지
      $keyName = "tf-ds-$(Get-Date -Format 'yyyyMMddHHmmss')"
      $apiKey = (aws grafana create-workspace-api-key `
        --key-name $keyName --key-role "ADMIN" --seconds-to-live 300 `
        --workspace-id $workspaceId --region $region `
        --output json | ConvertFrom-Json).key
      $headers = @{ "Authorization" = "Bearer $apiKey"; "Content-Type" = "application/json" }

      $body = @{
        name      = "AMP-y2ks"
        type      = "prometheus"
        url       = $ampUrl
        access    = "proxy"
        isDefault = $true
        jsonData  = @{
          httpMethod    = "POST"
          sigV4Auth     = $true
          sigV4AuthType = "default"
          sigV4Region   = $region
        }
      } | ConvertTo-Json -Depth 5

      # 기존 datasource 조회 → 있으면 PUT, 없으면 POST (upsert)
      try {
        $existing = Invoke-RestMethod -Uri "$grafanaUrl/api/datasources/name/AMP-y2ks" -Headers $headers -ErrorAction Stop
        Invoke-RestMethod -Uri "$grafanaUrl/api/datasources/$($existing.id)" -Method PUT -Headers $headers -Body $body | Out-Null
        Write-Host "AMP datasource 업데이트 완료"
      } catch {
        Invoke-RestMethod -Uri "$grafanaUrl/api/datasources" -Method POST -Headers $headers -Body $body | Out-Null
        Write-Host "AMP datasource 생성 완료"
      }
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $workspaceId = "${self.triggers.workspace_id}"
      $region = "${self.triggers.region}"
      $grafanaUrl = "https://$workspaceId.grafana-workspace.$region.amazonaws.com"

      $keyName = "tf-destroy-$(Get-Date -Format 'yyyyMMddHHmmss')"
      $apiKey = (aws grafana create-workspace-api-key `
        --key-name $keyName --key-role "ADMIN" --seconds-to-live 120 `
        --workspace-id $workspaceId --region $region `
        --output json | ConvertFrom-Json).key
      $headers = @{ "Authorization" = "Bearer $apiKey"; "Content-Type" = "application/json" }

      try {
        $existing = Invoke-RestMethod -Uri "$grafanaUrl/api/datasources/name/AMP-y2ks" -Headers $headers -ErrorAction Stop
        Invoke-RestMethod -Uri "$grafanaUrl/api/datasources/$($existing.id)" -Method DELETE -Headers $headers | Out-Null
        Write-Host "AMP datasource 삭제 완료"
      } catch {
        Write-Host "AMP datasource 없음, 스킵"
      }
    EOT
  }

  depends_on = [
    aws_grafana_workspace.main,
    aws_prometheus_workspace.main,
    null_resource.prometheus_stack
  ]
}

# ============================================================
# AMG user permissions - auto grant ADMIN to all SSO users
# ============================================================
data "aws_ssoadmin_instances" "main" {}

data "aws_identitystore_users" "all" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.main.identity_store_ids)[0]
}

resource "aws_grafana_role_association" "admins" {
  for_each = {
    for u in data.aws_identitystore_users.all.users : u.user_id => u
  }

  workspace_id = aws_grafana_workspace.main.id
  role         = "ADMIN"
  user_ids     = [each.value.user_id]
}

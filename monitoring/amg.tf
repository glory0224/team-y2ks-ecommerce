# ============================================================
# Amazon Managed Grafana (AMG) workspace
# IAM Identity Center(SSO) 인증 사용
# ============================================================
resource "aws_grafana_workspace" "main" {
  name                     = var.amg_workspace_name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.amg.arn

  data_sources = ["PROMETHEUS", "CLOUDWATCH"]

  tags = {
    Project = "y2ks"
  }
}

# ============================================================
# AMG IAM Role
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

# AMP 쿼리 권한
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

# CloudWatch 읽기 권한
resource "aws_iam_role_policy_attachment" "amg_cloudwatch" {
  role       = aws_iam_role.amg.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

# ============================================================
# AMG에 AMP datasource 연결 (upsert)
# ============================================================
resource "null_resource" "amg_datasource" {
  triggers = {
    workspace_id    = aws_grafana_workspace.main.id
    amp_endpoint    = aws_prometheus_workspace.main.prometheus_endpoint
    region          = var.aws_region
    iam_policy_hash = sha256(aws_iam_role_policy.amg_amp_query.policy)
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $workspaceId = "${aws_grafana_workspace.main.id}"
      $region      = "${var.aws_region}"
      $ampUrl      = "${trimsuffix(aws_prometheus_workspace.main.prometheus_endpoint, "/")}"
      $grafanaUrl  = "https://$workspaceId.grafana-workspace.$region.amazonaws.com"

      $keyName = "tf-ds-$(Get-Date -Format 'yyyyMMddHHmmss')"
      $apiKey = (aws grafana create-workspace-api-key `
        --key-name $keyName --key-role "ADMIN" --seconds-to-live 300 `
        --workspace-id $workspaceId --region $region `
        --output json | ConvertFrom-Json).key
      $headers = @{ "Authorization" = "Bearer $apiKey"; "Content-Type" = "application/json" }

      $body = @{
        name      = "AMP-y2ks"
        uid       = "AMP-y2ks"
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
      $region      = "${self.triggers.region}"
      $grafanaUrl  = "https://$workspaceId.grafana-workspace.$region.amazonaws.com"

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
    aws_iam_role_policy.amg_amp_query,
    null_resource.prometheus_stack
  ]
}

# ============================================================
# AMG user permissions - SSO 사용자 전원 ADMIN
# aws_grafana_role_association은 SERVICE_MANAGED workspace에서
# destroy 시 404 에러가 발생하므로 null_resource + AWS CLI로 처리
# workspace 삭제 시 권한도 함께 삭제되므로 destroy provisioner 불필요
# ============================================================
data "aws_ssoadmin_instances" "main" {}

data "aws_identitystore_users" "all" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.main.identity_store_ids)[0]
}

resource "null_resource" "amg_user_permissions" {
  triggers = {
    workspace_id = aws_grafana_workspace.main.id
    user_ids     = join(",", [for u in data.aws_identitystore_users.all.users : u.user_id])
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $workspaceId = "${aws_grafana_workspace.main.id}"
      $region      = "${var.aws_region}"
      $userIds     = "${join(",", [for u in data.aws_identitystore_users.all.users : u.user_id])}".Split(",")

      foreach ($userId in $userIds) {
        $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
        $batch = "[{`"action`":`"ADD`",`"role`":`"ADMIN`",`"users`":[{`"id`":`"$userId`",`"type`":`"SSO_USER`"}]}]"
        [System.IO.File]::WriteAllText($tmpFile, $batch, [System.Text.Encoding]::ASCII)
        aws grafana update-permissions `
          --workspace-id $workspaceId `
          --update-instruction-batch "file://$tmpFile" `
          --region $region | Out-Null
        Remove-Item $tmpFile
        Write-Host "권한 부여 완료: $userId"
      }
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = "Write-Host 'workspace 삭제 시 권한도 함께 삭제됨'"
  }

  depends_on = [aws_grafana_workspace.main]
}

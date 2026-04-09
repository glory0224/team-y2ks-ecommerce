# ============================================================
# KEDA + Karpenter 대시보드 프로비저닝
# - 폴더/대시보드 upsert: 이미 존재해도 overwrite
# - destroy 시 폴더째 삭제
# ============================================================
resource "null_resource" "amg_dashboards" {
  triggers = {
    workspace_id   = aws_grafana_workspace.main.id
    region         = var.aws_region
    dashboard_hash = sha256(join("", [
      file("${path.module}/dashboards/keda.json"),
      file("${path.module}/dashboards/karpenter.json"),
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $workspaceId = "${aws_grafana_workspace.main.id}"
      $region = "${var.aws_region}"
      $grafanaUrl = "https://$workspaceId.grafana-workspace.$region.amazonaws.com"

      $keyName = "tf-dash-$(Get-Date -Format 'yyyyMMddHHmmss')"
      $apiKey = (aws grafana create-workspace-api-key `
        --key-name $keyName --key-role "ADMIN" --seconds-to-live 300 `
        --workspace-id $workspaceId --region $region `
        --output json | ConvertFrom-Json).key
      $headers = @{ "Authorization" = "Bearer $apiKey"; "Content-Type" = "application/json" }

      # 폴더 upsert: uid로 조회 후 없으면 생성, 있으면 그대로 사용
      $folderUid = "y2ks-monitoring"
      $folder = $null
      try {
        $folder = Invoke-RestMethod -Uri "$grafanaUrl/api/folders/$folderUid" -Headers $headers -ErrorAction Stop
      } catch {}

      if (-not $folder) {
        try {
          $folder = Invoke-RestMethod -Uri "$grafanaUrl/api/folders" -Method POST -Headers $headers `
            -Body (@{ uid = $folderUid; title = "Y2KS Monitoring" } | ConvertTo-Json)
        } catch {
          # 동시 생성 경쟁 등으로 실패 시 다시 조회
          $folder = Invoke-RestMethod -Uri "$grafanaUrl/api/folders/$folderUid" -Headers $headers
        }
      }
      $folderId = $folder.id

      # 대시보드 upsert (overwrite: true 로 멱등 보장)
      foreach ($file in @("${path.module}/dashboards/keda.json", "${path.module}/dashboards/karpenter.json")) {
        $dashboard = Get-Content $file -Raw | ConvertFrom-Json
        $payload = @{ dashboard = $dashboard; folderId = $folderId; overwrite = $true } | ConvertTo-Json -Depth 20
        Invoke-RestMethod -Uri "$grafanaUrl/api/dashboards/db" -Method POST -Headers $headers -Body $payload | Out-Null
        Write-Host "대시보드 등록 완료: $($dashboard.title)"
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

      # 폴더 삭제 (하위 대시보드 포함)
      try {
        Invoke-RestMethod -Uri "$grafanaUrl/api/folders/y2ks-monitoring" -Method DELETE -Headers $headers | Out-Null
        Write-Host "Y2KS Monitoring 폴더 삭제 완료"
      } catch {
        Write-Host "폴더 없음, 스킵"
      }
    EOT
  }

  depends_on = [null_resource.amg_datasource]
}

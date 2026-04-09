output "amp_workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.main.id
}

output "amp_endpoint" {
  description = "AMP remote_write endpoint"
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}

output "amg_workspace_id" {
  description = "AMG workspace ID"
  value       = aws_grafana_workspace.main.id
}

output "amg_endpoint" {
  description = "AMG Grafana URL"
  value       = "https://${aws_grafana_workspace.main.endpoint}"
}

output "next_steps" {
  description = "적용 후 안내"
  value       = <<-EOT
    [완료]
    - AMP workspace: ${aws_prometheus_workspace.main.id}
    - AMG Grafana URL: https://${aws_grafana_workspace.main.endpoint}

    [AMG 사용자 접근 권한 부여]
    terraform apply 시 IAM Identity Center 전체 유저를 자동 조회하여 AMG ADMIN 권한을 부여합니다.
    별도 설정 없이 apply 만 하면 됩니다.

    [Prometheus remote_write 확인]
    kubectl get prometheus -n monitoring prometheus-kube-prometheus-prometheus -o jsonpath='{.spec.remoteWrite}'
  EOT
}

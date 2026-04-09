# ============================================================
# SQS 앱 큐 — 쿠폰 신청 메시지 처리
# 기존: setup.py가 런타임에 생성하던 큐를 Terraform으로 관리
# ============================================================
resource "aws_sqs_queue" "app" {
  name                       = "y2ks-queue"
  message_retention_seconds  = 86400  # 1일
  visibility_timeout_seconds = 30
  sqs_managed_sse_enabled    = true
}

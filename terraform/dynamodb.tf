# ============================================================
# DynamoDB 쿠폰 발급 기록 테이블
# 기존: aws dynamodb create-table --table-name y2ks-coupon-claims ...
# ============================================================
resource "aws_dynamodb_table" "claims" {
  name         = "y2ks-coupon-claims"
  billing_mode = "PAY_PER_REQUEST" # 요청 수만큼 과금 (서버리스)
  hash_key     = "request_id"      # PK: UUID

  attribute {
    name = "request_id"
    type = "S" # String
  }

  # 저장되는 필드 (attribute 선언 불필요 - DynamoDB는 스키마리스)
  # - status      : "winner" / "loser"
  # - coupon_code : "Y2KS-XXXX-XXXX" (당첨자만)
  # - claimed_at  : ISO 타임스탬프
  # - email       : 당첨자 이메일 (나중에 추가)
  # - email_sent  : true / false

  tags = {
    Project = "y2ks-ecommerce"
    Purpose = "coupon-claims"
  }
}

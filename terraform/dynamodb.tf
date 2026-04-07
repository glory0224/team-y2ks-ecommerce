# ============================================================
# DynamoDB table for coupon claim records (y2ks-coupon-claims)
# ============================================================
resource "aws_dynamodb_table" "claims" {
  name         = "y2ks-coupon-claims"
  billing_mode = "PAY_PER_REQUEST" # Serverless - pay per request
  hash_key     = "request_id"      # PK: UUID

  attribute {
    name = "request_id"
    type = "S" # String
  }

  # Schema-less fields stored per item (no attribute declaration needed):
  # - status      : "winner" / "loser"
  # - coupon_code : "Y2KS-XXXX-XXXX" (winners only)
  # - claimed_at  : ISO timestamp
  # - email       : winner email (updated after submission)
  # - email_sent  : true / false

  tags = {
    Project = "y2ks-ecommerce"
    Purpose = "coupon-claims"
  }
}

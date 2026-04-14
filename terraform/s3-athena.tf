

resource "aws_s3_bucket" "athena" {
  bucket = "y2ks-athena-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "athena_public_block" {
  bucket                  = aws_s3_bucket.athena.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "athena_versioning" {
  bucket = aws_s3_bucket.athena.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_lifecycle" {
  bucket = aws_s3_bucket.athena.id

  rule {
    id     = "archive-k6-raw"
    status = "Enabled"

    filter {
      prefix = "k6/raw/"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }

  rule {
    id     = "delete-k6-processed"
    status = "Enabled"

    filter {
      prefix = "k6/processed/"
    }

    expiration {
      days = 180
    }
  }
}

output "athena_bucket_name" {
  value = aws_s3_bucket.athena.bucket
}

output "athena_bucket_arn" {
  value = aws_s3_bucket.athena.arn
}

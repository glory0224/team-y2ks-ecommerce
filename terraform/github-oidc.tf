# ============================================================
# GitHub Actions OIDC — k6 부하테스트용
# ============================================================
data "aws_region" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub Actions OIDC thumbprint (고정값)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_k6" {
  name        = "Y2ksGitHubK6Role"
  description = "GitHub Actions k6 load test - Datalake Pipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # glory0224/team-y2ks-ecommerce 레포의 모든 브랜치/태그 허용
          "token.actions.githubusercontent.com:sub" = "repo:glory0224/team-y2ks-ecommerce:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_k6_amp" {
  name = "GitHubK6AMPWritePolicy"
  role = aws_iam_role.github_k6.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:RemoteWrite"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "github_k6_datalake" {
  name = "GitHubK6DatalakePolicy"
  role = aws_iam_role.github_k6.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketAcl"
        ]
        Resource = [
          "arn:aws:s3:::y2ks-athena-*",
          "arn:aws:s3:::y2ks-athena-*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:GetWorkGroup"
        ]
        Resource = "arn:aws:athena:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workgroup/y2ks-analytics"
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetDatabase",
          "glue:GetPartitions",
          "glue:CreateTable",
          "glue:CreatePartition",
          "glue:BatchCreatePartition",
          "glue:UpdateTable",
          "glue:UpdatePartition"
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/y2ks_analytics",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/y2ks_analytics/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload",
          "s3:CreateBucket",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::aws-athena-query-results-*"
        ]
      }
    ]
  })
}

output "github_k6_role_arn" {
  description = "GitHub Actions k6 워크플로우에서 사용할 IAM Role ARN"
  value       = aws_iam_role.github_k6.arn
}

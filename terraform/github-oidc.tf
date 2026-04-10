# ============================================================
# GitHub Actions OIDC — k6 부하테스트용
# AMP Remote Write 권한만 부여 (최소 권한)
# ============================================================
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub Actions OIDC thumbprint (고정값)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_k6" {
  name        = "Y2ksGitHubK6Role"
  description = "GitHub Actions k6 load test - AMP Remote Write only"

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

output "github_k6_role_arn" {
  description = "GitHub Actions k6 워크플로우에서 사용할 IAM Role ARN"
  value       = aws_iam_role.github_k6.arn
}

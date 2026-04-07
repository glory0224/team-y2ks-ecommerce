# ============================================================
# Worker IAM (concert-frontend + concert-worker 파드용)
# 기존: worker-policy.json + worker-trust-policy.json + AWS CLI
# ============================================================
resource "aws_iam_policy" "worker" {
  name        = "ModoWorkerPolicy"
  description = "SQS 수신/삭제, SES 이메일 발송 권한"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:SendMessage"
        ]
        Resource = "arn:aws:sqs:${var.aws_region}:${var.account_id}:ticket-queue"
      },
      {
        Sid      = "SESAccess"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_policy" "worker_dynamodb" {
  name        = "ModoWorkerDynamoDB"
  description = "DynamoDB 쿠폰 발급 기록 읽기/쓰기 권한"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ]
      # eks.tf의 DynamoDB 테이블 ARN을 직접 참조 (하드코딩 없음)
      Resource = aws_dynamodb_table.claims.arn
    }]
  })
}

resource "aws_iam_role" "worker" {
  name        = "ModoWorkerRole"
  description = "IRSA: worker-sa ServiceAccount가 사용하는 IAM 역할"

  # OIDC를 통해 Kubernetes ServiceAccount와 연동 (토큰/시크릿 불필요)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # eks.tf의 local.oidc_issuer를 자동 참조 (하드코딩 없음)
          "${local.oidc_issuer}:sub" = "system:serviceaccount:default:worker-sa"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_main" {
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.worker.arn
}

resource "aws_iam_role_policy_attachment" "worker_dynamodb" {
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.worker_dynamodb.arn
}

# ============================================================
# KEDA Operator IAM
# 기존: keda-operator-trust-policy.json + AWS CLI
# ============================================================
resource "aws_iam_role" "keda_operator" {
  name        = "KedaOperatorRole"
  description = "IRSA: keda-operator가 SQS 메시지 수를 읽기 위한 IAM 역할"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:keda:keda-operator"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "keda_sqs" {
  role       = aws_iam_role.keda_operator.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSReadOnlyAccess"
}

# ============================================================
# Karpenter Node IAM
# 기존: karpenter-cfn.yaml (CloudFormation)의 KarpenterNodeRole
# ============================================================
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile-${var.cluster_name}"
  role = aws_iam_role.karpenter_node.name
}

# ============================================================
# Karpenter Controller IAM
# 기존: karpenter-cfn.yaml의 KarpenterControllerPolicy
# ============================================================
resource "aws_iam_role" "karpenter_controller" {
  name = "KarpenterControllerRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "KarpenterControllerPolicy-${var.cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances", "ec2:TerminateInstances",
          "ec2:DescribeInstances", "ec2:DescribeInstanceTypes",
          "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates", "ec2:DescribeSpotPriceHistory",
          "ec2:CreateFleet", "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate", "ec2:CreateTags",
          "pricing:GetProducts", "ssm:GetParameter"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ============================================================
# Karpenter Spot 인터럽트 알림용 SQS
# 기존: karpenter-cfn.yaml의 SQS 리소스
# ============================================================
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "KarpenterInterruption-${var.cluster_name}"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

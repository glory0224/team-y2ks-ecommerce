# ============================================================
# EKS 클러스터 IAM Role
# ============================================================
resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ============================================================
# EKS 클러스터
# ============================================================
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids             = aws_subnet.public[*].id
    endpoint_public_access = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ============================================================
# OIDC Provider (IRSA용 - IAM과 Kubernetes 연동)
# ============================================================
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# OIDC URL (https:// 제거한 버전 - IAM 조건문에 사용)
locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# ============================================================
# 노드그룹 공통 IAM Role
# ============================================================
resource "aws_iam_role" "node_group" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

# ============================================================
# 노드그룹 1: standard-nodes (t3.micro - 시스템 파드 전용)
# ============================================================
resource "aws_eks_node_group" "standard" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "standard-nodes"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = ["t3.micro"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  tags = {
    "alpha.eksctl.io/cluster-name" = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# ============================================================
# 노드그룹 2: app-nodes (t3.small - 앱 파드 전용)
# t3.micro는 MaxPods=4로 부족 → t3.small = MaxPods=11
# ============================================================
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "app-nodes"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = ["t3.small"]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 10
  }

  tags = {
    "alpha.eksctl.io/cluster-name" = var.cluster_name
    "karpenter.sh/discovery"       = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# ============================================================
# Karpenter가 보안그룹을 찾을 수 있도록 클러스터 SG에 discovery 태그 추가
# EKS가 자동 생성하는 cluster security group에는 이 태그가 없음
# ============================================================
resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# ============================================================
# EKS 애드온 (시스템 컴포넌트)
# ============================================================
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"
  depends_on   = [aws_eks_node_group.standard]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.standard]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_node_group.standard]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "metrics-server"
  depends_on   = [aws_eks_node_group.standard]
}

# ============================================================
# EKS 클러스터 접근 권한 (terraform 실행 유저 자동 등록)
# terraform apply를 실행한 IAM 유저에게 자동으로 cluster-admin 부여
# ============================================================
resource "aws_eks_access_entry" "terraform_runner" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "terraform_runner_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_caller_identity.current.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.terraform_runner]
}

# ============================================================
# EKS 클러스터 접근 권한 (팀원 자동 등록)
# variables.tf의 team_member_usernames에 추가하면
# terraform apply만으로 kubectl 권한 자동 부여
# ============================================================
resource "aws_eks_access_entry" "team" {
  for_each = toset(var.team_member_usernames)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${each.value}"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "team_admin" {
  for_each = toset(var.team_member_usernames)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${each.value}"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.team]
}

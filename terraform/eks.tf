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

  # 현재 실행 중인 IAM 유저의 이름 추출 (예: user02)
  # ARN이 'arn:aws:iam::123456789012:user/user02' 형식일 때 마지막 부분을 가져옴
  current_session_user = element(split("/", data.aws_caller_identity.current.arn), length(split("/", data.aws_caller_identity.current.arn)) - 1)

  # 팀원 목록에서 현재 실행 중인 유저를 제외 (중복 방지)
  filtered_team_members = toset([for u in var.team_member_usernames : u if u != local.current_session_user])
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
# 노드그룹 1: ondemand-1 (AZ-a, t3.medium)
# - node-type=ondemand-1 라벨 → payment 파드 고정 배치
# - 부하 발생 시 Karpenter가 스팟 노드 자동 추가
# ============================================================
resource "aws_eks_node_group" "ondemand_node1" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ondemand-1"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = [aws_subnet.public[0].id]
  instance_types  = ["t3.medium"]

  labels = {
    "node-type" = "ondemand-1"
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  tags = {
    "alpha.eksctl.io/cluster-name" = var.cluster_name
    "karpenter.sh/discovery"       = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_internet_gateway.main,
  ]
}

# ============================================================
# 노드그룹 2: ondemand-2 (AZ-b, t3.medium)
# - node-type=ondemand-2 라벨 → cart, product 파드 고정 배치
# ============================================================
resource "aws_eks_node_group" "ondemand_node2" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ondemand-2"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = [aws_subnet.public[1].id]
  instance_types  = ["t3.medium"]

  labels = {
    "node-type" = "ondemand-2"
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  tags = {
    "alpha.eksctl.io/cluster-name" = var.cluster_name
    "karpenter.sh/discovery"       = var.cluster_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_internet_gateway.main,
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
  depends_on   = [aws_eks_node_group.ondemand_node1, aws_eks_node_group.ondemand_node2]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.ondemand_node1, aws_eks_node_group.ondemand_node2]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_node_group.ondemand_node1, aws_eks_node_group.ondemand_node2]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "metrics-server"
  depends_on   = [aws_eks_node_group.ondemand_node1, aws_eks_node_group.ondemand_node2]
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
  for_each = local.filtered_team_members

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${each.value}"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "team_admin" {
  for_each = local.filtered_team_members

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${each.value}"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.team]
}

# ============================================================
# Karpenter 노드 EKS 접근 등록
# 없으면 Karpenter가 프로비저닝한 노드가 클러스터에 조인 불가
# ============================================================
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  depends_on = [aws_eks_cluster.main]
}

# ============================================================
# VPC
# ============================================================
data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                        = "${var.cluster_name}-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  # EKS 클러스터 삭제 후 AWS가 자동 생성한 SG/ENI 잔류로 VPC 삭제 실패하는 문제 방지
  # aws_vpc destroy provisioner는 EKS 클러스터·노드그룹 삭제 완료 후 실행되므로
  # 이 시점에 in-use ENI 해제를 기다리고 남은 SG를 정리한다
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "SilentlyContinue"
      $VpcId = "${self.id}"
      Write-Host "=== VPC 삭제 전 잔여 리소스 정리 (VPC: $VpcId) ==="

      # [1/4] K8s가 생성한 Classic LB / ALB / NLB 삭제 (EKS 삭제 후 남는 외부 LB)
      Write-Host "[1/4] K8s 생성 Load Balancer 삭제..."
      $lbs = aws elb describe-load-balancers `
        --query "LoadBalancerDescriptions[?VPCId=='$VpcId'].LoadBalancerName" `
        --output text --region ap-northeast-2 2>$null
      foreach ($lb in ($lbs -split "\s+" | Where-Object { $_ })) {
        Write-Host "  CLB 삭제: $lb"
        aws elb delete-load-balancer --load-balancer-name $lb --region ap-northeast-2 2>$null
      }
      $albArns = aws elbv2 describe-load-balancers `
        --query "LoadBalancers[?VpcId=='$VpcId'].LoadBalancerArn" `
        --output text --region ap-northeast-2 2>$null
      foreach ($arn in ($albArns -split "\s+" | Where-Object { $_ })) {
        Write-Host "  ALB/NLB 삭제: $arn"
        aws elbv2 delete-load-balancer --load-balancer-arn $arn --region ap-northeast-2 2>$null
      }
      Write-Host "  LB 삭제 후 ENI 해제 대기 (30초)..."
      Start-Sleep -Seconds 30

      # [2/4] in-use ENI 해제 대기 (EKS control plane ENI는 클러스터 삭제 후 AWS가 자동 해제)
      Write-Host "[2/4] in-use ENI 해제 대기 (최대 3분)..."
      for ($i = 0; $i -lt 18; $i++) {
        $inuse = aws ec2 describe-network-interfaces `
          --filters "Name=vpc-id,Values=$VpcId" "Name=status,Values=in-use" `
          --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>$null
        if (-not $inuse -or $inuse -match "^\s*$") {
          Write-Host "[OK] in-use ENI 없음"
          break
        }
        Write-Host "  대기중 in-use ENI: $inuse"
        Start-Sleep -Seconds 10
      }

      # [3/4] available ENI 삭제
      Write-Host "[3/4] available ENI 삭제..."
      $avail = aws ec2 describe-network-interfaces `
        --filters "Name=vpc-id,Values=$VpcId" "Name=status,Values=available" `
        --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>$null
      foreach ($eni in ($avail -split "\s+" | Where-Object { $_ })) {
        Write-Host "  ENI 삭제: $eni"
        aws ec2 delete-network-interface --network-interface-id $eni 2>$null
      }

      # [4/4] EKS 자동생성 SG 삭제 (Terraform 관리 외 — eks-cluster-sg-* 등, default 제외)
      Write-Host "[4/4] 잔여 SG 삭제..."
      $sgs = aws ec2 describe-security-groups `
        --filters "Name=vpc-id,Values=$VpcId" `
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>$null
      foreach ($sg in ($sgs -split "\s+" | Where-Object { $_ })) {
        Write-Host "  SG 삭제 시도: $sg"
        aws ec2 delete-security-group --group-id $sg 2>$null
      }
      Write-Host "=== VPC 사전정리 완료 ==="
    EOT
  }
}

# ============================================================
# 퍼블릭 서브넷 (3개 AZ) - LoadBalancer, 노드 배치용
# ============================================================
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet("192.168.0.0/16", 3, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-${count.index}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "alpha.eksctl.io/cluster-name"              = var.cluster_name
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

# ============================================================
# Internet Gateway
# ============================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# ============================================================
# 퍼블릭 라우트 테이블
# ============================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

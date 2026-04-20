# ============================================================
# ECR 리포지토리 — 의존성이 사전 설치된 커스텀 이미지 관리
# pip install을 컨테이너 시작마다 실행하는 문제 해결
# ============================================================
resource "aws_ecr_repository" "frontend" {
  name                 = "y2ks-frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "worker" {
  name                 = "y2ks-worker"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "agent" {
  name                 = "y2ks-agent"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ============================================================
# Docker 이미지 빌드 & ECR 푸시
# terraform apply 시 Dockerfile 변경 감지 → 자동 재빌드
# ============================================================
resource "null_resource" "build_and_push_images" {
  triggers = {
    frontend_dockerfile = sha256(file("${path.module}/../Dockerfile.frontend"))
    worker_dockerfile   = sha256(file("${path.module}/../Dockerfile.worker"))
    agent_dockerfile    = sha256(file("${path.module}/../Dockerfile.agent"))
  }

  provisioner "local-exec" {
    interpreter = ["C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", "-Command"]
    command     = <<-EOT
      $region  = "${var.aws_region}"
      $ecrBase = "${data.aws_caller_identity.current.account_id}.dkr.ecr.$region.amazonaws.com"

      Write-Host "=== ECR 로그인 ==="
      $ecrPassword = aws ecr get-login-password --region $region
      docker login --username AWS --password "$ecrPassword" $ecrBase
      if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] ECR 로그인 실패"; exit 1 }

      Write-Host "=== frontend 이미지 빌드 & 푸시 ==="
      docker build -t y2ks-frontend -f ${path.module}/../Dockerfile.frontend ${path.module}/..
      docker tag y2ks-frontend:latest "${aws_ecr_repository.frontend.repository_url}:latest"
      docker push "${aws_ecr_repository.frontend.repository_url}:latest"
      if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] frontend 푸시 실패"; exit 1 }

      Write-Host "=== worker 이미지 빌드 & 푸시 ==="
      docker build -t y2ks-worker -f ${path.module}/../Dockerfile.worker ${path.module}/..
      docker tag y2ks-worker:latest "${aws_ecr_repository.worker.repository_url}:latest"
      docker push "${aws_ecr_repository.worker.repository_url}:latest"
      if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] worker 푸시 실패"; exit 1 }

      Write-Host "=== agent 이미지 빌드 & 푸시 ==="
      docker build -t y2ks-agent -f ${path.module}/../Dockerfile.agent ${path.module}/..
      docker tag y2ks-agent:latest "${aws_ecr_repository.agent.repository_url}:latest"
      docker push "${aws_ecr_repository.agent.repository_url}:latest"
      if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] agent 푸시 실패"; exit 1 }

      Write-Host "=== 빌드 & 푸시 완료 ==="
    EOT
  }

  depends_on = [
    aws_ecr_repository.frontend,
    aws_ecr_repository.worker,
    aws_ecr_repository.agent,
    null_resource.kubeconfig,
  ]
}

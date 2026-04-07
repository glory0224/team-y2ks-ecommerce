# Y2KS Fashion - EKS 쿠폰 이벤트 시스템

고트래픽 선착순 쿠폰 이벤트를 AWS EKS 위에서 운영하는 패션 쇼핑몰 시스템입니다.  
KEDA + Karpenter로 트래픽 스파이크를 자동 대응합니다.

---

## 아키텍처

```
[사용자]
   │
   ▼
[Y2KS 쇼핑몰 메인 /]  →  [이벤트 페이지 /event]
                                  │
                         버튼 클릭 → POST /api/claim
                                  │
                           [SQS Queue]  ←── KEDA가 메시지 수 감지
                                │                    │
                          [Worker Pod]  ──────── Scale Out (1 → 50)
                                │            (Karpenter → EC2 노드 자동 추가)
                       ┌────────┴────────┐
                       │                 │
                    당첨 (tickets > 0) 낙첨 (tickets = 0)
                       │                 │
                 [DynamoDB 기록]   [DynamoDB 기록]
                       │
             이메일 입력 → SES 발송
```

---

## 구성 요소

| 서비스 | 역할 | 기술 |
|--------|------|------|
| y2ks-frontend | 쇼핑몰 UI + API 서버 (메인/이벤트/관리자 페이지) | Flask + Gunicorn |
| y2ks-worker | SQS 메시지 소비 → 쿠폰 당첨/낙첨 판정 | Python + boto3 |
| Redis | 실시간 티켓 카운터 + 결과 임시 저장 | Redis Alpine |
| DynamoDB | 쿠폰 발급 이력 영구 저장 | AWS DynamoDB (PAY_PER_REQUEST) |
| SES | 당첨자 쿠폰 이메일 발송 | AWS SES |
| KEDA | SQS 큐 깊이 기반 Worker 자동 스케일링 (1~50) | KEDA v2 |
| Karpenter | 부하 시 EC2 Spot 노드 자동 프로비저닝/제거 | Karpenter v1.1.1 |

---

## 파일 구조

```
.
├── terraform/                  # AWS 인프라 + 전체 배포 자동화
│   ├── main.tf                 # 사전 요구사항 확인, kubeconfig, KEDA/Karpenter/앱 배포
│   ├── variables.tf            # 변수 (cluster_name, region, team_member_usernames 등)
│   ├── vpc.tf                  # VPC, 서브넷, 라우팅
│   ├── eks.tf                  # EKS 클러스터, 노드그룹, 애드온, OIDC, 접근 권한
│   ├── iam.tf                  # IAM Role/Policy (Worker, KEDA, Karpenter)
│   ├── dynamodb.tf             # DynamoDB 쿠폰 클레임 테이블
│   └── outputs.tf              # 배포 후 참조값 출력 + next_steps 안내
│
└── helm/y2ks/                  # Y2KS 앱 Helm 차트
    ├── Chart.yaml
    ├── values.yaml             # 변수 정의 (terraform apply 시 자동 주입)
    └── templates/
        ├── aws-config.yaml     # AWS 설정 ConfigMap (SQS URL, Region, DDB 테이블)
        ├── configmap-code.yaml # Python 코드 (app.py, worker.py, setup.py)
        ├── configmap-html.yaml # HTML 페이지 (main, event, admin)
        ├── frontend.yaml       # Frontend Deployment + LoadBalancer Service
        ├── worker.yaml         # Worker Deployment
        ├── redis.yaml          # Redis Deployment + Service
        ├── keda.yaml           # KEDA ScaledObject + TriggerAuthentication
        ├── karpenter.yaml      # Karpenter EC2NodeClass + NodePool
        ├── priority-classes.yaml
        ├── rbac.yaml
        └── setup-job.yaml      # SQS/DynamoDB 초기화 Job
```

---

## 사전 요구사항

아래 도구들이 로컬에 설치되어 있어야 합니다. `terraform apply` 시 자동으로 확인하며 없으면 설치 링크와 함께 오류를 출력합니다.

| 도구 | 설치 링크 |
|------|-----------|
| AWS CLI | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| kubectl | https://kubernetes.io/docs/tasks/tools/ |
| Helm | https://helm.sh/docs/intro/install/ |

---

## 배포 방법

### 1. AWS 자격증명 설정

```bash
aws configure
# AWS Access Key ID: 본인 키 입력
# AWS Secret Access Key: 본인 시크릿 입력
# Default region name: ap-northeast-2
```

### 2. 배포 (전체 자동화)

```bash
cd terraform
terraform init   # 처음 한 번만
terraform apply
```

`terraform apply` 한 번으로 아래가 모두 자동 실행됩니다:

- VPC / EKS 클러스터 / IAM / DynamoDB 생성
- 실행한 IAM 유저에게 kubectl 접근 권한 자동 부여
- kubeconfig 자동 업데이트
- KEDA, Karpenter Helm 설치
- worker-sa ServiceAccount 생성 + IRSA 연결
- Y2KS 앱 전체 배포 (계정 ID는 aws configure에서 자동으로 읽어옴)

### 3. 접속 URL 확인

```bash
kubectl get svc y2ks-frontend-svc
# EXTERNAL-IP 컬럼의 주소로 브라우저 접속
```

---

## 코드 수정 후 재배포

```bash
cd terraform
terraform apply
```

`helm/y2ks/templates/` 안의 파일이 변경되면 `terraform apply` 시 자동으로 감지하여 재배포합니다.

---

## 클러스터 삭제

```bash
cd terraform
terraform destroy
```

---

## 주요 페이지

| URL | 설명 |
|-----|------|
| `/` | 쇼핑몰 메인 |
| `/event` | 쿠폰 이벤트 페이지 |
| `/admin` | 관리자 페이지 (이벤트 현황, 부하테스트, 파드/노드 모니터링) |

---

## 주요 설정값

| 항목 | 값 |
|------|----|
| 쿠폰 수량 | 100장 |
| SQS 큐 | y2ks-queue |
| DynamoDB 테이블 | y2ks-coupon-claims |
| KEDA 스케일 범위 | Worker 1 ~ 50개 |
| KEDA 트리거 | 메시지 5개당 Worker 1개 |
| Karpenter 인스턴스 | t3.small (Spot + On-demand) |

---

## PriorityClass

| 클래스 | 값 | 대상 | 설명 |
|--------|----|------|------|
| `y2ks-critical` | 100,000 | Redis | 절대 선점 불가 |
| `y2ks-high` | 10,000 | Frontend | 트래픽 스파이크 시에도 항상 보장 |
| `y2ks-normal` | 1,000 | Worker | 리소스 부족 시 선점 허용 |

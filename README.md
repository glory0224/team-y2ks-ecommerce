# Y2KS Fashion - EKS 쿠폰 이벤트 시스템

고트래픽 선착순 쿠폰 이벤트를 AWS EKS 위에서 운영하는 패션 쇼핑몰 시스템입니다.  
KEDA + Karpenter로 트래픽 스파이크를 자동 대응하며, Terraform 한 번으로 전체 인프라와 앱이 배포됩니다.

---

## 아키텍처

```
[사용자]
   │ HTTP
   ▼
[Internet Gateway] → [LoadBalancer Service]
                              │
                    [Frontend Pod × 2] (Flask + Gunicorn)
                              │
              ┌───────────────┼───────────────┐
              │               │               │
        POST /api/claim    Redis 폴링      정적 페이지
              │
         [SQS Queue]  ←── KEDA (메시지 수 감지)
              │                    │
        [Worker Pod]  ─── Scale Out (1 → 50)
              │            (Karpenter → EC2 노드 자동 추가)
       ┌──────┴──────┐
       │             │
  당첨 처리      낙첨 처리
       │
  [DynamoDB 당첨 이력 저장]  [Redis 결과 저장]  [로그인 조회로 결과 확인]
```

---

## 구성 요소

| 서비스 | 역할 | 기술 |
|--------|------|------|
| y2ks-frontend | 쇼핑몰 UI + API 서버 | Flask + Gunicorn |
| y2ks-worker | SQS 메시지 소비 → 쿠폰 당첨/낙첨 판정 | Python + boto3 |
| y2ks-cart | 장바구니 서비스 | Flask |
| y2ks-payment | 결제 서비스 | Flask |
| y2ks-product | 상품 서비스 | Flask |
| Redis | 실시간 티켓 카운터 + 결과 임시 저장 | Redis Alpine |
| DynamoDB | 쿠폰 발급 이력 영구 저장 | AWS DynamoDB (PAY_PER_REQUEST) |
| SQS | 쿠폰 요청 비동기 처리 버퍼 | AWS SQS |
| KEDA | SQS 큐 깊이 기반 Worker 자동 스케일링 (1~50) | KEDA v2 |
| Karpenter | 부하 시 EC2 노드 자동 프로비저닝/제거 | Karpenter v1.1.1 |
| Prometheus | 파드/노드 메트릭 수집 | kube-prometheus-stack |
| Grafana | KEDA / Karpenter / k6 대시보드 시각화 | Grafana (monitoring 네임스페이스) |
| k6 | 선착순 이벤트 부하 테스트 | k6 Job (EKS 내 실행) |

---

## 파일 구조

```
.
├── Dockerfile.frontend         # Frontend 이미지
├── Dockerfile.worker           # Worker 이미지
│
├── terraform/                  # AWS 인프라 + 전체 배포 자동화
│   ├── main.tf                 # Prometheus/KEDA/Karpenter/앱 배포 자동화
│   ├── variables.tf            # 변수 (cluster_name, region, grafana_admin_password 등)
│   ├── vpc.tf                  # VPC, 서브넷, 라우팅
│   ├── eks.tf                  # EKS 클러스터, 노드그룹, 애드온, OIDC, 접근 권한
│   ├── iam.tf                  # IAM Role/Policy (Worker, KEDA, Karpenter, k6)
│   ├── dynamodb.tf             # DynamoDB 쿠폰 클레임 테이블
│   ├── sqs.tf                  # SQS 큐 (y2ks-queue)
│   ├── ecr.tf                  # ECR 리포지토리 + Docker 이미지 빌드/푸시 자동화
│   ├── github-oidc.tf          # GitHub Actions OIDC (k6 부하테스트용)
│   └── outputs.tf              # 배포 후 참조값 출력 + next_steps 안내
│
├── helm/y2ks/                  # Y2KS 앱 Helm 차트
│   ├── Chart.yaml
│   ├── values.yaml             # 변수 정의 (terraform apply 시 자동 주입)
│   ├── dashboards/             # Grafana 대시보드 JSON (KEDA, Karpenter, k6)
│   ├── prometheus-values.yaml  # kube-prometheus-stack Helm values
│   └── templates/
│       ├── aws-config.yaml         # AWS 설정 ConfigMap
│       ├── configmap-code.yaml     # Python 코드 (app.py, worker.py)
│       ├── configmap-html.yaml     # HTML 페이지 (main, event, admin)
│       ├── configmap-k6.yaml       # k6 부하 테스트 스크립트
│       ├── frontend.yaml           # Frontend Deployment + LoadBalancer Service
│       ├── cart.yaml               # 장바구니 Deployment
│       ├── payment.yaml            # 결제 Deployment
│       ├── product.yaml            # 상품 Deployment
│       ├── worker.yaml             # Worker Deployment (KEDA 스케일 대상)
│       ├── redis.yaml              # Redis Deployment + Service
│       ├── keda.yaml               # KEDA ScaledObject + TriggerAuthentication
│       ├── karpenter.yaml          # Karpenter EC2NodeClass + NodePool
│       ├── priority-classes.yaml   # PriorityClass 정의
│       └── pdb.yaml                # PodDisruptionBudget (Redis, Frontend)
│
└── k6/
    └── job.yaml                # k6 부하 테스트 Job (EKS 내 실행)
```

---

## 사전 요구사항

| 도구 | 설치 링크 |
|------|-----------|
| AWS CLI | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| kubectl | https://kubernetes.io/docs/tasks/tools/ |
| Helm | https://helm.sh/docs/intro/install/ |
| Docker Desktop | https://docs.docker.com/get-docker/ |

> Docker Desktop은 ECR 이미지 빌드/푸시에 필요합니다. kubectl만 사용하는 팀원은 불필요합니다.

---

## 배포 방법

### 1. AWS 자격증명 설정

```powershell
aws configure
# AWS Access Key ID: 본인 키 입력
# AWS Secret Access Key: 본인 시크릿 입력
# Default region name: ap-northeast-2
```

### 2. 팀원 IAM 유저명 등록

`terraform/variables.tf`의 `team_member_usernames`에 팀원 IAM 유저명을 추가하면 `terraform apply` 시 자동으로 kubectl 접근 권한이 부여됩니다.

```hcl
variable "team_member_usernames" {
  default = ["user01", "user02", "user03", "user04"]
}
```

### 3. 배포 (전체 자동화)

> **팀에서 한 명만 실행하면 됩니다.**

```powershell
cd terraform
terraform init
terraform apply
```

`terraform apply` 한 번으로 아래가 모두 자동 실행됩니다:

- VPC / EKS 클러스터 / IAM / DynamoDB / SQS 생성
- ECR 리포지토리 생성 + Dockerfile 기반 이미지 빌드 & ECR 푸시
- 팀원 IAM 유저에게 kubectl 접근 권한 자동 부여
- kubeconfig 자동 업데이트
- Prometheus + Grafana / KEDA / Karpenter Helm 설치
- worker-sa ServiceAccount 생성 + IRSA 연결
- Y2KS 앱 전체 배포 (Frontend, Worker, Cart, Payment, Product, Redis)

---

## 팀원 환경 설정

배포가 완료된 상태에서 팀원은 아래만 실행하면 됩니다.

```powershell
# 1. AWS 자격증명 설정
aws configure

# 2. kubeconfig 업데이트
aws eks update-kubeconfig --region ap-northeast-2 --name y2ks-eks-cluster

# 3. 접속 확인
kubectl get nodes
```

---

## 접속 URL 확인

```powershell
kubectl get svc y2ks-frontend-svc
# EXTERNAL-IP 컬럼의 주소로 브라우저 접속
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
| 쿠폰 수량 | 기본값 100장 (`helm/y2ks/values.yaml`의 `ticketCount`로 조정) |
| SQS 큐 | y2ks-queue |
| DynamoDB 테이블 | y2ks-coupon-claims |
| KEDA 스케일 범위 | Worker 1 ~ 50개 |
| KEDA 트리거 | 메시지 10개당 Worker 1개 |
| Karpenter 인스턴스 | CPU 8코어 미만 (On-Demand + Spot 혼합) |
| Karpenter CPU 한도 | 20코어 |
| Karpenter consolidation | 10분 후 통합 |
| Grafana 비밀번호 | `variables.tf`의 `grafana_admin_password` (기본값: `admin123!`) |

---

## PriorityClass

| 클래스 | 값 | 대상 | 설명 |
|--------|----|------|------|
| `y2ks-critical` | 100,000 | Redis | 절대 선점 불가 |
| `y2ks-high` | 10,000 | Frontend, k6 | 트래픽 스파이크 시에도 항상 보장 |
| `y2ks-normal` | 1,000 | Worker | 리소스 부족 시 선점 허용 |
| `y2ks-low` | 100 | Cart / Payment / Product | Karpenter 한도 초과 시 Worker에게 자리 양보 |

---

## 모니터링 (Grafana)

Prometheus + Grafana는 `monitoring` 네임스페이스에 배포됩니다.  
`terraform apply` 시 자동으로 설치되며 별도 설정 없이 바로 사용 가능합니다.

### Grafana 접속

```powershell
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# 브라우저: http://localhost:3000
# ID: admin / PW: variables.tf의 grafana_admin_password (기본값: admin123!)
```

### 대시보드

**KEDA ScaledObjects** (`/d/y2ks-keda`)

| 패널 | 의미 |
|------|------|
| ScaledObject - Current Replicas | KEDA가 현재 측정하는 메트릭 값 (SQS 메시지 수 기반) |
| ScaledObject - Active | 스케일링 활성 여부 (1: 스케일링 중, 0: 대기) |
| SQS Queue Depth | y2ks-queue 미처리 메시지 수 |
| Worker Replicas | Worker Pod 현재/목표 수 |
| KEDA Operator - Errors | 스케일링 판단 중 오류 수 |

**Karpenter Node Autoscaling** (`/d/y2ks-karpenter`)

| 패널 | 의미 |
|------|------|
| Nodes by NodePool | NodePool별 노드 수 추이 |
| Total Cluster Nodes | 클러스터 전체 노드 수 |
| Pending Pods | 배치 대기 중인 Pod 수 |
| Node Provisioning Duration (p99) | 노드 생성 소요시간 |
| NodeClaims Launched / Terminated | 노드 생성/삭제 속도 |

**k6 Load Test** (`/d/y2ks-k6`)

| 패널 | 의미 |
|------|------|
| Virtual Users | 현재 동시 요청 수 |
| HTTP Request Rate | 초당 성공 요청 수 |
| Response Time Percentiles | p50/p95/p99 응답시간 |
| Claim Success / Fail Rate | 성공 vs 실패 req/s |

---

## 부하 테스트 (k6)

```powershell
# 티켓 초기화
kubectl exec deployment/y2ks-frontend -c web -- python3 -c \
  "import redis; r = redis.Redis(host='redis-service'); r.set('tickets', 100)"

# k6 실행
kubectl delete job k6-loadtest --ignore-not-found
kubectl apply -f k6/job.yaml

# 로그 확인
kubectl logs -f job/k6-loadtest -c k6
```

**시나리오** (총 4분)

| 구간 | 시간 | VU 수 |
|------|------|-------|
| ramp-up | 30s | 0 → 50 |
| ramp-up | 2m | 50 → 200 |
| sustained | 1m | 200 |
| ramp-down | 30s | 200 → 0 |

---

## 코드 수정 후 재배포

```powershell
cd terraform
terraform apply
```

`helm/y2ks/templates/` 파일 변경 시 자동 감지 후 재배포됩니다.  
`Dockerfile.frontend` 또는 `Dockerfile.worker` 변경 시 ECR 이미지도 자동으로 재빌드 & 푸시됩니다.

---

## 클러스터 삭제

> **주의:** 한 명이 실행하면 팀 전체 인프라가 삭제됩니다. 팀원에게 사전 공유 후 실행하세요.

```powershell
cd terraform
terraform destroy
```

삭제 순서:
1. Karpenter ASG 직접 삭제 (AWS CLI)
2. Y2KS 앱 삭제 → ELB 삭제 확인
3. Karpenter / KEDA / Prometheus Helm 삭제
4. ECR 이미지 및 리포지토리 삭제
5. EKS 클러스터 / 노드그룹 / IAM / VPC 삭제

---

## 멀티 에이전트

AWS Strands Agents SDK + Amazon Bedrock 기반의 EKS 운영 자동화 에이전트입니다.  
관리자 페이지(`/admin`)에서 질문을 입력하면 에이전트가 자동으로 전문가를 선택해 분석합니다.

### 구성

```
사용자 질문 (관리자 페이지 / Slack)
        ↓
   [Router] - Claude Sonnet 4.6
        ↓
단일 전문가              복수 전문가
    ↓                       ↓
직접 처리             전문가끼리 핸드오프
                    EKS ↔ DB ↔ Observe
                          ↓
               [Orchestrator] - Claude Sonnet 4.6
```

| 에이전트 | 모델 | 담당 |
|---------|------|------|
| Router | Claude Sonnet 4.6 | 질문 분석 → 전문가 선택 |
| EKS Agent | Claude Haiku 3 | kubectl / KEDA / Karpenter / SQS |
| DB Agent | Claude Haiku 3 | DynamoDB / 봇 탐지 / 참여 분석 |
| Observe Agent | Claude Haiku 3 | 리소스 / 비용 / 성능 |
| Orchestrator | Claude Sonnet 4.6 | 교차 분석 + 최종 판단 |

### 설치

> ⚠️ Python 3.14는 anyio 4.x와 충돌합니다. **Python 3.12** 사용하세요.

```powershell
winget install Python.Python.3.12

cd agents
py -3.12 -m venv venv312
venv312\Scripts\activate
pip install strands-agents boto3 python-dotenv slack_bolt
```

AWS 콘솔 → Bedrock → Model access에서 아래 모델 활성화 필요:
- `Claude Sonnet 4` (APAC 리전)
- `Claude Haiku 3` (APAC 리전)

### 환경변수

`agents/.env` 파일 생성:

```env
AWS_REGION=ap-northeast-2
DDB_TABLE=y2ks-coupon-claims
SQS_QUEUE_URL=https://sqs.ap-northeast-2.amazonaws.com/{ACCOUNT_ID}/y2ks-queue
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
```

### 실행

```powershell
cd agents
venv312\Scripts\activate

# Slack 봇
python slack_bot.py

# CLI
python eks_agent.py --query "지금 Pending 파드 있어?"
python eks_agent.py --auto           # 전체 자동 진단
```

### 파일 구조

```
agents/
├── eks_agent.py        # 에이전트 + 라우터 + 오케스트레이터
├── eks_mcp_server.py   # MCP 툴 서버 (kubectl + boto3 + Prometheus)
├── slack_bot.py        # Slack 봇
├── main.py             # 순차 실행 버전
├── requirements.txt    # Python 패키지 목록
└── .env                # 환경변수
```


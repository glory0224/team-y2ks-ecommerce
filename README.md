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
| Prometheus | 파드/노드 메트릭 수집 → admin 모니터링 페이지 연동 | prometheus-community/prometheus |

---

## 파일 구조

```
.
├── Dockerfile.frontend         # Frontend 이미지 (pip install 사전 완료 → 컨테이너 시작 즉시 실행)
├── Dockerfile.worker           # Worker 이미지 (pip install 사전 완료 → 컨테이너 시작 즉시 실행)
│
├── terraform/                  # AWS 인프라 + 전체 배포 자동화
│   ├── main.tf                 # 사전 요구사항 확인, kubeconfig, Prometheus/KEDA/Karpenter/앱 배포
│   ├── variables.tf            # 변수 (cluster_name, region, team_member_usernames 등)
│   ├── vpc.tf                  # VPC, 서브넷, 라우팅
│   ├── eks.tf                  # EKS 클러스터, 노드그룹, 애드온, OIDC, 접근 권한
│   ├── iam.tf                  # IAM Role/Policy (Worker, KEDA, Karpenter) + EventBridge + SQS 정책
│   ├── dynamodb.tf             # DynamoDB 쿠폰 클레임 테이블
│   ├── sqs.tf                  # SQS 앱 큐 (y2ks-queue)
│   ├── ecr.tf                  # ECR 리포지토리 + Docker 이미지 빌드/푸시 자동화
│   └── outputs.tf              # 배포 후 참조값 출력 + next_steps 안내
│
└── helm/y2ks/                  # Y2KS 앱 Helm 차트
    ├── Chart.yaml
    ├── values.yaml             # 변수 정의 (terraform apply 시 자동 주입)
    └── templates/
        ├── aws-config.yaml     # AWS 설정 ConfigMap (SQS URL, Region, DDB 테이블)
        ├── configmap-code.yaml # Python 코드 (app.py, worker.py)
        ├── configmap-html.yaml # HTML 페이지 (main, event, admin)
        ├── frontend.yaml       # Frontend Deployment + LoadBalancer Service
        ├── worker.yaml         # Worker Deployment
        ├── redis.yaml          # Redis Deployment + Service
        ├── keda.yaml           # KEDA ScaledObject + TriggerAuthentication
        ├── karpenter.yaml      # Karpenter EC2NodeClass + NodePool
        ├── priority-classes.yaml
        └── rbac.yaml
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
| Docker Desktop | https://docs.docker.com/get-docker/ |

> Docker Desktop은 `terraform apply` 시 ECR 이미지 빌드/푸시에 필요합니다. kubectl만 사용하는 팀원은 불필요합니다.

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
  default = ["user01", "user02", "user04"]  # 실제 IAM 유저명으로 변경
}
```

### 3. 배포 (전체 자동화)

> **팀에서 한 명만 실행하면 됩니다.** 나머지 팀원은 아래 [팀원 환경 설정](#팀원-환경-설정) 참고.

```powershell
cd terraform
terraform init   # S3 remote backend 연결 (처음 한 번만)
terraform apply
```

`terraform apply` 한 번으로 아래가 모두 자동 실행됩니다:

- VPC / EKS 클러스터 / IAM / DynamoDB / SQS 큐 생성
- ECR 리포지토리 생성 + Dockerfile 기반 이미지 빌드 & ECR 푸시
- 실행한 IAM 유저에게 kubectl 접근 권한 자동 부여
- kubeconfig 자동 업데이트
- Prometheus / KEDA / Karpenter Helm 설치
- worker-sa ServiceAccount 생성 + IRSA 연결
- Y2KS 앱 전체 배포 (계정 ID는 aws configure에서 자동으로 읽어옴)

---

## S3 tfstate 및 팀 협업

Terraform state는 S3 버킷(`y2ks-terraform-state-951913065915`)에 저장됩니다.  
GitHub 코드와 별개로 관리되며, `terraform apply/destroy` 시에만 업데이트됩니다.

| | GitHub | S3 tfstate |
|--|--------|-----------|
| 저장 내용 | `.tf` 코드 | AWS 현재 인프라 상태 |
| 언제 바뀜 | git push/pull | terraform apply/destroy |

### 팀원 환경 설정

배포는 이미 완료된 상태입니다. 팀원은 아래만 실행하면 됩니다.

**kubectl만 사용하는 경우 (terraform 불필요)**
```powershell
# 1. AWS 자격증명 설정
aws configure

# 2. kubeconfig 업데이트
aws eks update-kubeconfig --region ap-northeast-2 --name y2ks-eks-cluster

# 3. 접속 확인
kubectl get nodes
```

**terraform apply/destroy도 실행해야 하는 경우**
```powershell
git pull
cd terraform
terraform init   # S3 state 연결 (처음 한 번만)
# Docker Desktop도 실행 중이어야 함
```

---

### 접속 URL 확인

```powershell
kubectl get svc y2ks-frontend-svc
# EXTERNAL-IP 컬럼의 주소로 브라우저 접속
```

---

## 코드 수정 후 재배포

```powershell
cd terraform
terraform apply
```

`helm/y2ks/templates/` 안의 파일이 변경되면 `terraform apply` 시 자동으로 감지하여 재배포합니다.  
`Dockerfile.frontend` 또는 `Dockerfile.worker`가 변경되면 ECR 이미지도 자동으로 재빌드 & 푸시됩니다.

---

## 클러스터 삭제

> **주의:** S3 state를 공유하므로 한 명이 실행하면 팀 전체 인프라가 삭제됩니다. 팀원에게 사전 공유 후 실행하세요.

```powershell
cd terraform
terraform destroy
```

아래 순서로 자동 정리됩니다:
1. Karpenter 노드 drain 및 삭제
2. Y2KS 앱 삭제 → LoadBalancer(ELB) 삭제 → ENI 해제
3. Karpenter / KEDA / Prometheus Helm 삭제
4. ECR 이미지 및 리포지토리 삭제
5. EKS 클러스터 / 노드그룹 / IAM / VPC 삭제

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
| 쿠폰 수량 | 기본값 100장 (`helm/y2ks/values.yaml`의 `ticketCount`로 조정 가능) |
| SQS 큐 | y2ks-queue |
| DynamoDB 테이블 | y2ks-coupon-claims |
| KEDA 스케일 범위 | Worker 1 ~ 50개 |
| KEDA 트리거 | 메시지 5개당 Worker 1개 |
| 기본 노드그룹 | system-nodes t3.small × 2 (시스템·앱 파드 공용) |
| Karpenter 인스턴스 | t3.small (Spot + On-demand) |
| 발신 이메일 | wooseoyun@naver.com |

---

## PriorityClass

| 클래스 | 값 | 대상 | 설명 |
|--------|----|------|------|
| `y2ks-critical` | 100,000 | Redis | 절대 선점 불가 |
| `y2ks-high` | 10,000 | Frontend | 트래픽 스파이크 시에도 항상 보장 |
| `y2ks-normal` | 1,000 | Worker | 리소스 부족 시 선점 허용 |

---


## 모니터링 (AWS Managed Grafana)

KEDA와 Karpenter의 스케일링 동작을 AMP + AMG로 시각화합니다.  
기존 `terraform/` 과 완전히 분리된 독립 state로 관리됩니다.

### 아키텍처

```
[EKS 클러스터]
  └── monitoring 네임스페이스
        └── prometheus (kube-prometheus-stack)
              │  scrape: keda-operator, karpenter, kube-state-metrics, node-exporter
              │  remote_write (SigV4 / IRSA)
              ▼
        [AMP - Amazon Managed Prometheus]
              │  query (SigV4 / workspace IAM role)
              ▼
        [AMG - Amazon Managed Grafana]
              │  IAM Identity Center(SSO) 로그인
              └── KEDA / Karpenter / k6 Load Test 대시보드

[k6 부하 테스트 Job]
  └── k6 컨테이너
        │  --out experimental-prometheus-rw
        │  → localhost:8005 (SigV4 proxy 사이드카)
        ▼
  [SigV4 proxy 사이드카]
        │  AWS SigV4 서명 후 AMP에 직접 remote_write
        ▼
  [AMP → AMG k6 Load Test 대시보드]
```

### 배포

```bash
cd monitoring
terraform init   # 처음 한 번만
terraform apply
```

`terraform apply` 한 번으로 아래가 모두 자동 실행됩니다:

- AMP workspace 생성
- AMG workspace 생성 (IAM Identity Center SSO 인증)
- kube-prometheus-stack 설치 (AMP remote_write + KEDA/Karpenter ServiceMonitor 포함)
- AMG에 AMP datasource 자동 연결
- KEDA / Karpenter / k6 Load Test 대시보드 프로비저닝
- IAM Identity Center에 등록된 전체 사용자에게 AMG ADMIN 권한 자동 부여
- k6 부하 테스트용 ConfigMap (`y2ks-k6-config`) 자동 생성 — AMP workspace ID 포함

### IAM Identity Center 사용자 생성

Grafana 로그인에 필요합니다. 사용자 추가 후 `terraform apply` 재실행 시 AMG 권한이 자동 부여됩니다.

AWS 콘솔 → IAM Identity Center → Users → "Add user" → Username / Email / 이름 입력  
→ 이메일로 임시 비밀번호 전송됨

### Grafana 접속

AMG는 IAM Identity Center SSO 세션 기반이므로 **포털 로그인 후 AMG URL로 이동**해야 합니다.  
AMG URL로 직접 접근하면 세션이 없어 오류가 발생합니다.

1. IAM Identity Center 포털 로그인  
   AWS 콘솔 → IAM Identity Center → Dashboard → "AWS access portal URL" 확인  
   (`https://d-xxxxxxxxxx.awsapps.com/start`)

2. 이메일 / 임시 비밀번호로 로그인 → 비밀번호 변경

3. 포털 로그인 완료 후 아래 URL로 이동

```bash
cd monitoring && terraform output amg_endpoint
```

### 대시보드

---

**KEDA ScaledObjects** (`/d/y2ks-keda`)

KEDA가 SQS 메시지 수를 기반으로 Worker Pod를 자동 스케일링하는 과정을 보여줍니다.

| 패널 | 의미 |
|------|------|
| ScaledObject - Current Replicas | KEDA scaler가 현재 측정하는 메트릭 값. SQS 메시지 수가 올라갈수록 이 값이 커지고 Worker 스케일아웃이 트리거됩니다 |
| ScaledObject - Active | ScaledObject가 현재 활성 상태인지 여부. 1이면 스케일링 중, 0이면 대기 상태 |
| SQS Queue Depth | y2ks-queue에 쌓인 미처리 메시지 수. 부하 테스트 시 급증하고 Worker가 처리하면서 감소합니다 |
| Worker Replicas | Worker Deployment의 현재(Current) vs 목표(Desired) Pod 수. KEDA가 SQS depth를 보고 Desired를 올리면 Current가 따라 올라갑니다 |
| KEDA Operator - Errors | KEDA가 스케일링 판단 중 발생한 오류 수. 정상이면 0에 가깝습니다 |
| ScaledObject Reconcile Duration | KEDA가 ScaledObject 상태를 재평가하는 데 걸리는 시간. 값이 크면 스케일링 반응이 느려집니다 |

---

**Karpenter Node Autoscaling** (`/d/y2ks-karpenter`)

Pending Pod가 생기면 Karpenter가 새 EC2 노드를 자동으로 프로비저닝하는 과정을 보여줍니다.

| 패널 | 의미 |
|------|------|
| Nodes by NodePool | NodePool별 현재 노드 수 추이. 부하 증가 시 노드가 추가되고 부하 감소 시 제거됩니다 |
| Total Cluster Nodes | 클러스터 전체 노드 수. 스케일아웃/인 결과를 한눈에 확인합니다 |
| Pending Pods | 아직 노드에 배치되지 못한 Pod 수. 이 값이 올라가면 Karpenter가 새 노드를 프로비저닝합니다 |
| Node Provisioning Duration (p99) | 노드 생성 요청부터 Pod가 실제로 시작되기까지 걸린 시간의 p99. 값이 크면 콜드 스타트 지연이 있다는 의미입니다 |
| NodeClaims Launched / Terminated | 초당 노드 생성/삭제 속도. 부하 테스트 시 Launched가 급증하고 테스트 종료 후 Terminated가 올라옵니다 |
| Node CPU Allocatable vs Requested | 노드별 할당 가능한 CPU와 실제 요청된 CPU 비교. Requested가 Allocatable에 가까워지면 Karpenter가 새 노드를 추가합니다 |
| Node Memory Allocatable vs Requested | 노드별 할당 가능한 메모리와 실제 요청된 메모리 비교. CPU와 동일한 방식으로 스케일링 판단에 사용됩니다 |

---

**k6 Load Test** (`/d/y2ks-k6`)

k6가 `/api/claim`에 부하를 주는 동안 애플리케이션 성능과 인프라 반응을 함께 보여줍니다.

| 패널 | 의미 |
|------|------|
| Virtual Users (VU) | 현재 동시 요청 수(Active)와 최대 설정 VU 수(Max). ramp-up → 유지 → ramp-down 곡선이 보입니다 |
| HTTP Request Rate | 초당 성공 요청 수(req/s). VU가 올라갈수록 함께 증가합니다 |
| Response Time Percentiles | p50(중간값) / p95 / p99 응답시간. p99가 p50보다 크게 높으면 일부 요청에서 지연이 발생하는 것입니다 |
| Claim Success / Fail Rate | `/api/claim` 성공 vs 실패 req/s. 실패가 0에 가까우면 정상입니다 |
| SQS Queue Depth during Load Test | 부하 중 SQS에 쌓이는 메시지 수. k6가 요청을 보내는 속도가 Worker 처리 속도보다 빠를 때 쌓입니다 |
| Worker Replicas during Load Test | 부하 중 KEDA가 Worker를 몇 개까지 늘렸는지. SQS depth 증가 → KEDA 스케일아웃 → Worker 증가 순서로 반응합니다 |

---

### 부하 테스트

k6 Job은 `k6/` 폴더에서 독립적으로 관리됩니다.  
`monitoring apply` 완료 후 아래 명령어로 실행합니다.

**사전 조건**

- `cd monitoring && terraform apply` 완료 — `y2ks-k6-config` ConfigMap 자동 생성됨
- `worker-sa` ServiceAccount에 `aps:RemoteWrite` 권한 포함 (`terraform/iam.tf`)

**실행**

```bash
# 티켓 초기화 (이전 테스트 데이터 제거)
kubectl exec deployment/y2ks-frontend -c web -- python3 -c \
  "import redis; r = redis.Redis(host='redis-service'); r.set('tickets', 100)"

# k6 부하 테스트 시작
kubectl delete job k6-loadtest --ignore-not-found
kubectl apply -f k6/job.yaml

# 실시간 로그 확인
kubectl logs -f job/k6-loadtest -c k6
```

**시나리오** (총 4분)

| 구간 | 시간 | VU 수 | 설명 |
|------|------|-------|------|
| ramp-up | 30s | 0 → 50 | 워밍업 |
| ramp-up | 2m | 50 → 200 | 최대 부하 |
| sustained | 1m | 200 | 유지 |
| ramp-down | 30s | 200 → 0 | 쿨다운 |

**메트릭 흐름**

```
k6 → SigV4 proxy sidecar (localhost:8005) → AMP → Grafana k6 Load Test 대시보드
```

k6가 SigV4 proxy 사이드카를 통해 AMP에 직접 메트릭을 씁니다.  
`monitoring apply/destroy` 시 AMP workspace ID가 담긴 ConfigMap이 자동으로 생성/삭제되므로  
별도 설정 없이 `kubectl apply -f k6/job.yaml`만 실행하면 됩니다.

### 부하 테스트 시 확인 순서

```
1. k6 Load Test 대시보드  → VU 증가, req/s, p50/p95/p99 응답시간 확인
2. KEDA 대시보드          → SQS Queue Depth 증가 → Worker Replicas 스케일아웃 확인
3. Karpenter 대시보드     → Pending Pods 증가 → Nodes Launched → CPU/Memory Requested 증가 확인
```

### 삭제

```bash
cd monitoring
terraform destroy
```

> 기존 `terraform/` 인프라(EKS, VPC 등)에는 영향 없음  
> destroy 시 k6 ConfigMap(`y2ks-k6-config`)도 자동 삭제됨

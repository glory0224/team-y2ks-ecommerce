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

KEDA와 Karpenter의 스케일링 동작을 Amazon Managed Prometheus(AMP) + Amazon Managed Grafana(AMG)로 시각화합니다.  
기존 `terraform/` 과 완전히 분리된 독립 state로 관리됩니다.

### 아키텍처

```
[EKS 클러스터]
  └── monitoring 네임스페이스
        └── prometheus (kube-prometheus-stack)
              │  scrape
              ├── keda-operator (port 9666)        ← KEDA 메트릭
              ├── karpenter (port 8080)             ← Karpenter 메트릭
              └── kube-state-metrics, node-exporter 등
              │
              │  remote_write (SigV4 / IRSA)
              ▼
        [AMP - Amazon Managed Prometheus]
              │
              │  query (SigV4 / workspace IAM role)
              ▼
        [AMG - Amazon Managed Grafana]
              │  IAM Identity Center(SSO) 로그인
              └── Y2KS Monitoring 폴더
                    ├── KEDA ScaledObjects 대시보드
                    └── Karpenter Node Autoscaling 대시보드
```

### 파일 구조

```
monitoring/
├── main.tf                   # provider, S3 backend (monitoring/terraform.tfstate)
├── variables.tf              # region, cluster_name, workspace 이름 등
├── amp.tf                    # AMP workspace + IRSA + kube-prometheus-stack 설치
├── amg.tf                    # AMG workspace + IAM role + datasource 연결
├── dashboards.tf             # KEDA / Karpenter 대시보드 프로비저닝
├── outputs.tf                # AMG URL, AMP endpoint 출력
├── prometheus-values.yaml    # kube-prometheus-stack helm values
│                             #   - AMP remote_write 설정
│                             #   - KEDA / Karpenter ServiceMonitor 정의
└── dashboards/
      ├── keda.json           # KEDA ScaledObjects 대시보드
      └── karpenter.json      # Karpenter Node Autoscaling 대시보드
```

### 배포

```bash
cd monitoring
terraform init
terraform apply
```

`terraform apply` 한 번으로 아래가 모두 자동 실행됩니다:

- AMP workspace 생성
- AMG workspace 생성 (IAM Identity Center 인증)
- kube-prometheus-stack 설치 (AMP remote_write + KEDA/Karpenter ServiceMonitor 포함)
- AMG에 AMP datasource 연결
- KEDA / Karpenter 대시보드 프로비저닝

### IAM Identity Center 사용자 생성 및 AMG 접근 설정

모니터링 배포 후 Grafana에 로그인하려면 IAM Identity Center 사용자가 필요합니다.

**1. 사용자 생성**

AWS 콘솔 → IAM Identity Center → Users → "Add user"

- Username, Email, First/Last name 입력
- 생성 후 이메일로 임시 비밀번호 전송됨

**2. MFA 설정 (선택)**

AWS 콘솔 → IAM Identity Center → Users → 해당 유저 → "MFA devices" → "Register MFA device"

- Authenticator app (Google Authenticator, Authy 등) 선택
- QR 코드 스캔 후 등록

**3. AMG workspace에 권한 부여**

IAM Identity Center 콘솔에서 User ID 복사 후 실행:

```bash
aws grafana update-permissions \
  --workspace-id <AMG_WORKSPACE_ID> \
  --update-instruction-batch '[{"action":"ADD","role":"ADMIN","users":[{"id":"<SSO_USER_ID>","type":"SSO_USER"}]}]' \
  --region ap-northeast-2
```

> `AMG_WORKSPACE_ID`와 `SSO_USER_ID`는 `terraform output` 또는 각 콘솔에서 확인합니다.

**4. Grafana 접속**

AMG는 IAM Identity Center SSO 세션 기반으로 동작하기 때문에 **반드시 아래 순서를 지켜야 합니다.**

```
❌ AMG URL 직접 접근 → SSO 세션 없음 → "문제가 발생했습니다" 오류
✅ IAM Identity Center 포털 로그인 → SSO 세션 생성 → AMG URL 접근 → 성공
```

**접속 순서:**

1. IAM Identity Center 포털 URL로 먼저 로그인

   AWS 콘솔 → IAM Identity Center → Dashboard → "AWS access portal URL" 확인  
   (형식: `https://d-xxxxxxxxxx.awsapps.com/start`)

2. 포털에서 이메일/임시 비밀번호로 로그인 → 비밀번호 변경 → MFA 등록

3. 로그인 완료 후 아래 AMG URL로 이동

```bash
cd monitoring
terraform output amg_endpoint
# https://<workspace-id>.grafana-workspace.ap-northeast-2.amazonaws.com
```

> terraform output URL로 직접 접근하면 SSO 세션이 없어 인증 오류가 발생합니다.  
> IAM Identity Center 포털에서 먼저 세션을 만든 뒤 AMG URL로 이동해야 합니다.  
> 이미 포털 로그인이 된 상태라면 AMG URL 직접 접근도 가능합니다.

### 대시보드 구성

**KEDA ScaledObjects** (`/d/y2ks-keda`)

| 패널 | 설명 | 데이터 없는 경우 |
|------|------|-----------------|
| ScaledObject - Current Replicas | scaler 메트릭 값 추이 | KEDA operator ServiceMonitor 미수집 시 |
| ScaledObject - Active | ScaledObject 일시정지 여부 (0=활성) | 동일 |
| SQS Queue Length | y2ks-queue 메시지 수 | KEDA가 SQS를 아직 폴링 안 한 경우 |
| Worker Replicas | Current vs Desired 비교 | kube-state-metrics 수집 후 표시 |
| KEDA Operator - Errors | 스케일링 실패율 | 정상 시 데이터 없음(에러 없음) |
| KEDA - ScaledObject Reconcile Duration | 스케일 루프 p99 지연 | KEDA 내부 메트릭 미노출 시 |

**Karpenter Node Autoscaling** (`/d/y2ks-karpenter`)

| 패널 | 설명 | 데이터 없는 경우 |
|------|------|-----------------|
| Nodes by Provisioner | nodepool별 노드 수 | Karpenter ServiceMonitor 미수집 시 |
| Total Cluster Nodes | 전체 노드 수 | kube-state-metrics 수집 후 표시 |
| Pending Pods | 스케줄 대기 파드 수 | 정상 시 0 |
| Karpenter - Nodes Launched / Terminated | 노드 생성/삭제 속도 | 스케일링 이벤트 없으면 데이터 없음 |
| Node Launch Duration (p99) | 노드 준비까지 걸린 시간 | 동일 |
| Node CPU/Memory Allocatable vs Requested | 노드별 리소스 여유 | 정상 수집 시 표시 |
| Karpenter - Disruption Decisions | consolidation/expiry 결정 수 | 이벤트 없으면 데이터 없음 |

### 대시보드 보는 순서

부하 테스트 시 아래 순서로 확인합니다:

```
1. Karpenter 대시보드
   → Total Cluster Nodes, Pending Pods 확인

2. KEDA 대시보드
   → SQS Queue Length 증가 확인
   → Worker Replicas 스케일아웃 확인

3. 다시 Karpenter 대시보드
   → Pending Pods 증가 → Nodes Launched 확인
   → Node CPU/Memory Requested 증가 확인
```

### 삭제

```bash
cd monitoring
terraform destroy
```

삭제 순서: 대시보드 → datasource → prometheus helm uninstall → AMP → AMG → IAM role

> 기존 `terraform/` 인프라(EKS, VPC 등)에는 영향 없음

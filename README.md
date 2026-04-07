# Y2KS Fashion - EKS 쿠폰 이벤트 시스템

고트래픽 선착순 쿠폰 이벤트를 AWS EKS 위에서 운영하는 패션 쇼핑몰 시스템입니다.
KEDA + Karpenter로 정각 트래픽 스파이크를 자동 대응합니다.

---

## 아키텍처

```
[사용자]
   │
   ▼
[쇼핑몰 메인 /]  →  [이벤트 페이지 /event]
                              │
                     버튼 클릭 (정각)
                              │
                    [Flask API /api/claim]
                              │
                         [SQS Queue]  ←── KEDA가 메시지 수 감지
                              │                    │
                        [Worker Pod]  ──────── Scale Out
                              │            (Karpenter → EC2 Spot 노드 추가)
                   ┌──────────┴──────────┐
                   │                     │
                당첨 (Redis)          낙첨 (Redis)
                   │                     │
             [DynamoDB 기록]       [DynamoDB 기록]
                   │
         이메일 입력 → SES 발송
```

---

## 구성 요소

| 서비스 | 역할 | 기술 |
|--------|------|------|
| concert-frontend | 쇼핑몰 UI + Flask API | Python 3.9 + gunicorn |
| concert-worker | SQS 메시지 소비, 당첨/낙첨 처리 | Python 3.9 + boto3 |
| Redis | 실시간 티켓 수량 및 결과 임시 저장 | Redis Alpine |
| DynamoDB | 쿠폰 발급 이력 영구 저장 | AWS DynamoDB (PAY_PER_REQUEST) |
| SES | 당첨자 쿠폰 이메일 발송 | AWS SES |
| KEDA | SQS 메시지 수 기반 Worker 자동 스케일링 | KEDA v2 |
| Karpenter | 부하 시 EC2 Spot 노드 자동 추가/제거 | Karpenter v1 |

---

## 파일 구조

```
.
├── terraform/
│   ├── main.tf             # Provider 설정, aws_caller_identity (계정 ID 자동 감지)
│   ├── variables.tf        # 클러스터명, 리전, k8s 버전, 발신 이메일
│   ├── vpc.tf              # VPC, 퍼블릭 서브넷 3개, IGW
│   ├── eks.tf              # EKS 클러스터, 노드그룹 2개, OIDC, Access Entry
│   ├── iam.tf              # Worker / KEDA / Karpenter IAM Role + Policy
│   ├── dynamodb.tf         # DynamoDB 테이블 (modo-coupon-claims)
│   └── outputs.tf          # 배포에 필요한 ARN, URL, 클러스터 정보 출력
├── app-deployment.yaml     # PriorityClass, RBAC, ConfigMap, Deployment, Service
├── redis.yaml              # Redis Deployment + ClusterIP Service
├── keda-scaledobject.yaml  # KEDA ScaledObject + TriggerAuthentication
├── karpenter-nodepool.yaml # EC2NodeClass + NodePool
└── deploy.sh               # KEDA/Karpenter Helm 설치 + yaml 적용 자동화
```

---

## 사전 요구사항

- AWS CLI — `aws configure` 완료
- Terraform >= 1.5
- kubectl
- helm
- envsubst (`gettext` 패키지)

---

## 배포 순서

```
[1] terraform apply          AWS 인프라 전체 생성
      │
[2] aws eks update-kubeconfig   클러스터 접근 설정
      │
[3] kubectl create serviceaccount worker-sa   IRSA 연결
      │
[4] kubectl apply -f redis.yaml
      │
[5] envsubst | kubectl apply -f app-deployment.yaml   앱 배포
      │
[6] bash deploy.sh           KEDA + Karpenter 설치 및 yaml 적용
```

---

### 1. Terraform — AWS 인프라 생성

```bash
cd terraform
terraform init
terraform apply
```

생성 리소스:

| 리소스 | 내용 |
|--------|------|
| VPC | 192.168.0.0/16, 퍼블릭 서브넷 3개 (AZ별) |
| EKS | v1.31, authentication_mode: API_AND_CONFIG_MAP |
| 노드그룹 | standard-nodes (t3.micro x2), app-nodes (t3.small x2) |
| IAM Role | ModoWorkerRole, KedaOperatorRole, KarpenterControllerRole, KarpenterNodeRole |
| DynamoDB | modo-coupon-claims (PAY_PER_REQUEST) |
| SQS | KarpenterInterruption-{cluster_name} (Spot 인터럽트 알림용) |
| Access Entry | 현재 `aws configure` 사용자를 클러스터 admin으로 자동 등록 |

> account ID는 `aws configure`에 설정된 값을 자동으로 읽습니다. 하드코딩 없음.

---

### 2. EKS — kubeconfig 업데이트

```bash
aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name $(terraform -chdir=terraform output -raw cluster_name)

kubectl get nodes   # 노드 4개 확인
```

---

### 3. Kubernetes — worker-sa ServiceAccount 생성 및 IRSA 연결

```bash
kubectl create serviceaccount worker-sa

kubectl annotate serviceaccount worker-sa \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw worker_role_arn)
```

---

### 4. Kubernetes — Redis 배포

```bash
kubectl apply -f redis.yaml
```

---

### 5. Kubernetes — 앱 배포

`app-deployment.yaml`과 `keda-scaledobject.yaml`에는 `${AWS_ACCOUNT_ID}`, `karpenter-nodepool.yaml`에는 `${CLUSTER_NAME}` 플레이스홀더가 있습니다.
`envsubst`로 치환 후 적용합니다.

```bash
export AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id)

envsubst < app-deployment.yaml | kubectl apply -f -
```

배포 확인:

```bash
kubectl get pods
# concert-frontend-xxx   1/1   Running
# concert-worker-xxx     1/1   Running
# aws-infra-setup-xxx    0/1   Completed   ← SQS 큐/DynamoDB 자동 생성 Job

kubectl get svc concert-frontend-svc
# EXTERNAL-IP 에 LoadBalancer URL이 나타날 때까지 1~2분 대기
```

---

### 6. Helm + Kubernetes — KEDA / Karpenter 설치

```bash
bash deploy.sh
```

`deploy.sh` 내부 흐름:

```
helm install keda                          KEDA 컨트롤러 설치
  └─ kubectl annotate keda-operator        IRSA 연결
  └─ envsubst | kubectl apply              keda-scaledobject.yaml 적용

helm install karpenter                     Karpenter 컨트롤러 설치
  └─ envsubst | kubectl apply              karpenter-nodepool.yaml 적용
```

---

## 최종 상태 확인

```bash
kubectl get pods -A
```

```
NAMESPACE     NAME                                    READY   STATUS
default       redis-xxx                               1/1     Running
default       concert-frontend-xxx                    1/1     Running
default       concert-worker-xxx                      1/1     Running
default       aws-infra-setup-xxx                     0/1     Completed
keda          keda-operator-xxx                       1/1     Running
keda          keda-admission-webhooks-xxx             1/1     Running
keda          keda-operator-metrics-apiserver-xxx     1/1     Running
karpenter     karpenter-xxx                           1/1     Running
```

```bash
kubectl get svc concert-frontend-svc
# EXTERNAL-IP 값이 접속 URL
```

---

## 부록

### DynamoDB 스키마 — modo-coupon-claims

| 필드 | 타입 | 설명 |
|------|------|------|
| `request_id` | String (PK) | 클릭 시 생성되는 UUID |
| `status` | String | `winner` / `loser` |
| `coupon_code` | String | 발급된 쿠폰 코드 (당첨자만) |
| `claimed_at` | String | 처리 ISO 타임스탬프 |
| `email` | String | 당첨자 이메일 |
| `email_sent` | Boolean | SES 발송 완료 여부 |

### PriorityClass

| 클래스 | 값 | 대상 | 설명 |
|--------|---|------|------|
| `modo-critical` | 100,000 | Redis | 절대 선점 불가 |
| `modo-high` | 10,000 | Frontend | 트래픽 스파이크 시에도 항상 보장 |
| `modo-normal` | 1,000 | Worker | 리소스 부족 시 선점 허용 |

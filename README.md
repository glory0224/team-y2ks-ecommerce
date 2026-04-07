# MODO Fashion - EKS 쿠폰 이벤트 시스템

**고트래픽 선착순 쿠폰 이벤트**를 AWS EKS 위에서 운영하는 패션 쇼핑몰 시스템입니다.  
KEDA + Karpenter로 정각 트래픽 스파이크를 자동 대응합니다.

---

## 📐 아키텍처

```
[사용자]
   │
   ▼
[MODO 쇼핑몰 메인]  →  [이벤트 페이지]
                              │
                     버튼 클릭 (정각)
                              │
                     [Flask API /api/claim]
                              │
                         [SQS Queue]  ←── KEDA가 메시지 수 감지
                              │                    │
                         [Worker Pod]  ──────── Scale Out
                              │            (Karpenter → 노드 추가)
                    ┌─────────┴─────────┐
                    │                   │
                 당첨 (Redis)       낙첨 (Redis)
                    │                   │
              [DynamoDB 기록]     [DynamoDB 기록]
                    │
          이메일 입력 → SES 발송
```

## 🧩 구성 요소

| 서비스 | 역할 | 기술 |
|--------|------|------|
| 쇼핑몰 Frontend | 사용자 UI (메인 + 이벤트 페이지) | Flask + gunicorn |
| SQS Worker | 쿠폰 처리 (당첨/낙첨 판정) | Python + boto3 |
| Redis | 실시간 폴링용 임시 상태 저장 | Redis Alpine |
| DynamoDB | 쿠폰 발급 이력 영구 저장 | AWS DynamoDB |
| SES | 당첨자 쿠폰 이메일 발송 | AWS SES |
| KEDA | SQS 메시지 수 기반 Worker 자동 스케일링 | KEDA v2 |
| Karpenter | 부하 시 EC2 Spot 노드 자동 추가/제거 | Karpenter v1 |

## 📦 PriorityClass

| 클래스 | 값 | 대상 | 설명 |
|--------|---|------|------|
| `modo-critical` | 100,000 | Redis | 절대 선점 불가 |
| `modo-high` | 10,000 | Frontend | 항상 사용자 접속 보장 |
| `modo-normal` | 1,000 | Worker | 리소스 부족 시 선점 허용 |

## 🗄️ DynamoDB 스키마

테이블명: `modo-coupon-claims`

| 필드 | 타입 | 설명 |
|------|------|------|
| `request_id` | String (PK) | 쿠폰 클릭 시 생성되는 UUID |
| `status` | String | `winner` / `loser` |
| `coupon_code` | String | 발급된 쿠폰 코드 (당첨자만) |
| `claimed_at` | String | 처리된 ISO 타임스탬프 |
| `email` | String | 당첨자 이메일 (제출 후 업데이트) |
| `email_sent` | Boolean | SES 발송 완료 여부 |

---

## 🚀 배포 순서

### 1. EKS 클러스터 생성
```bash
eksctl create cluster -f cluster.yaml
aws eks update-kubeconfig --region ap-northeast-2 --name y2ks-eks-cluster
```

### 2. IAM 역할 생성
```bash
# OIDC ID 확인
aws eks describe-cluster --name y2ks-eks-cluster \
  --query "cluster.identity.oidc.issuer" --output text

# worker-trust-policy.json, keda-operator-trust-policy.json 내
# OIDC ID를 실제 값으로 교체한 후:

aws iam create-policy --policy-name ModoWorkerPolicy \
  --policy-document file://worker-policy.json
aws iam create-role --role-name ModoWorkerRole \
  --assume-role-policy-document file://worker-trust-policy.json
aws iam attach-role-policy --role-name ModoWorkerRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/ModoWorkerPolicy
aws iam put-role-policy --role-name ModoWorkerRole \
  --policy-name DynamoDBAccess --policy-document file://dynamodb-policy.json

aws iam create-role --role-name KedaOperatorRole \
  --assume-role-policy-document file://keda-operator-trust-policy.json
aws iam attach-role-policy --role-name KedaOperatorRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSReadOnlyAccess
```

### 3. Kubernetes 리소스 배포
```bash
# 노드그룹 추가 (t3.small - 앱 파드용)
eksctl create nodegroup --cluster y2ks-eks-cluster \
  --name app-nodes --node-type t3.small --nodes 2 --managed

# ServiceAccount 생성 및 IRSA 연결
kubectl create serviceaccount worker-sa
kubectl annotate serviceaccount worker-sa \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/ModoWorkerRole

# Redis 및 앱 배포
kubectl apply -f redis.yaml
kubectl apply -f app-deployment.yaml
```

### 4. KEDA 설치
```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace

kubectl annotate serviceaccount keda-operator -n keda \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT_ID>:role/KedaOperatorRole
kubectl rollout restart deployment keda-operator -n keda

kubectl apply -f keda-scaledobject.yaml
```

### 5. Karpenter 설치
```bash
# CloudFormation 스택 배포
aws cloudformation deploy --template-file karpenter-cfn.yaml \
  --stack-name Karpenter-y2ks-eks-cluster \
  --capabilities CAPABILITY_NAMED_IAM

# Helm으로 Karpenter 설치 후
kubectl apply -f karpenter-nodepool.yaml
```

### 6. DynamoDB 테이블 생성
```bash
aws dynamodb create-table \
  --table-name modo-coupon-claims \
  --attribute-definitions AttributeName=request_id,AttributeType=S \
  --key-schema AttributeName=request_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-2
```

---

## ⚙️ 환경 변수 / 수정 필요 항목

배포 전 아래 값들을 본인 환경에 맞게 수정하세요:

- `app-deployment.yaml` → `QUEUE_URL`, `SENDER_EMAIL`
- `worker-trust-policy.json` → `<ACCOUNT_ID>`, `<OIDC_ID>`
- `keda-operator-trust-policy.json` → `<ACCOUNT_ID>`, `<OIDC_ID>`
- `karpenter-nodepool.yaml` → 클러스터명

---

## 📁 파일 구조

```
.
├── app-deployment.yaml       # ConfigMap(app.py, worker.py, HTML) + Deployments + Services
├── cluster.yaml              # EKS 클러스터 정의 (eksctl)
├── redis.yaml                # Redis Deployment + Service
├── karpenter-cfn.yaml        # Karpenter IAM CloudFormation 스택
├── karpenter-nodepool.yaml   # Karpenter NodePool + EC2NodeClass
├── keda-scaledobject.yaml    # KEDA ScaledObject + TriggerAuthentication
├── worker-policy.json        # Worker IAM Policy (SQS + SES + DynamoDB)
├── worker-trust-policy.json  # Worker IRSA Trust Policy
├── dynamodb-policy.json      # DynamoDB 추가 정책
├── keda-operator-trust-policy.json  # KEDA Operator IRSA Trust Policy
└── keda-identity-trust-policy.json  # KEDA Identity Trust Policy
```

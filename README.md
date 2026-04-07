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

## 파일 구조

```
.
├── terraform/
│   ├── main.tf           # Provider, aws_caller_identity (계정 ID 자동 감지)
│   ├── variables.tf      # 클러스터명, 리전, k8s 버전, 발신 이메일
│   ├── vpc.tf            # VPC, 퍼블릭 서브넷 3개, IGW
│   ├── eks.tf            # EKS 클러스터, 노드그룹, OIDC, Access Entry
│   ├── iam.tf            # Worker/KEDA/Karpenter IAM Role + Policy
│   ├── dynamodb.tf       # DynamoDB 테이블
│   └── outputs.tf        # 배포에 필요한 ARN, URL 출력
├── app-deployment.yaml   # PriorityClass, RBAC, ConfigMap, Deployment, Service
├── redis.yaml            # Redis Deployment + Service
├── keda-scaledobject.yaml    # KEDA ScaledObject + TriggerAuthentication
├── karpenter-nodepool.yaml   # EC2NodeClass + NodePool
└── deploy.sh             # KEDA/Karpenter Helm 설치 + yaml 적용 자동화
```

---

## 사전 요구사항

- AWS CLI (`aws configure` 완료)
- Terraform >= 1.5
- kubectl
- helm
- envsubst (`gettext` 패키지)

---

## 배포 순서

### 1. Terraform으로 AWS 인프라 생성

```bash
cd terraform
terraform init
terraform apply
```

생성되는 리소스:
- VPC + 퍼블릭 서브넷 3개
- EKS 클러스터 (v1.31)
- 노드그룹 2개: `standard-nodes` (t3.micro), `app-nodes` (t3.small)
- IAM Role: ModoWorkerRole, KedaOperatorRole, KarpenterControllerRole, KarpenterNodeRole
- DynamoDB 테이블: `modo-coupon-claims`
- Karpenter Interruption SQS 큐

> account ID는 `aws configure`에 설정된 값을 자동으로 읽습니다. 하드코딩 없음.

### 2. kubeconfig 업데이트

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name my-eks-cluster
kubectl get nodes  # 노드 4개 확인
```

노드가 안 보이면 Access Entry 문제입니다. 아래 명령으로 현재 IAM 유저를 클러스터 admin으로 등록하세요:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)

aws eks create-access-entry \
  --cluster-name my-eks-cluster \
  --principal-arn $USER_ARN \
  --region ap-northeast-2

aws eks associate-access-policy \
  --cluster-name my-eks-cluster \
  --principal-arn $USER_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region ap-northeast-2
```

> Terraform에 `aws_eks_access_entry` 리소스가 이미 포함되어 있어 `terraform apply` 시 자동 등록됩니다.

### 3. worker-sa ServiceAccount 생성 및 IRSA 연결

```bash
kubectl create serviceaccount worker-sa

kubectl annotate serviceaccount worker-sa \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw worker_role_arn)
```

> 이 단계를 건너뛰면 concert-frontend, concert-worker 파드가 생성되지 않습니다.

### 4. Redis 배포

```bash
kubectl apply -f redis.yaml
kubectl get pods  # redis Running 확인
```

### 5. 앱 배포

`app-deployment.yaml`에는 `${AWS_ACCOUNT_ID}` 플레이스홀더가 있어 `envsubst`로 치환 후 적용합니다.

```bash
AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id) \
  envsubst < app-deployment.yaml | kubectl apply -f -
```

배포 확인:

```bash
kubectl get pods
# concert-frontend-xxx   Running
# concert-worker-xxx     Running
# aws-infra-setup-xxx    Completed  (SQS 큐 자동 생성 Job)

kubectl get svc concert-frontend-svc
# EXTERNAL-IP 컬럼에 LoadBalancer URL이 나타날 때까지 1~2분 대기
```

### 6. KEDA + Karpenter 설치

`deploy.sh`가 Helm 설치부터 yaml 적용까지 한 번에 처리합니다.

```bash
bash deploy.sh
```

내부 동작 순서:
1. KEDA Helm 설치 → keda-operator IRSA 연결 → `keda-scaledobject.yaml` 적용
2. Karpenter Helm 설치 → `karpenter-nodepool.yaml` 적용

개별로 실행하려면:

```bash
# KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm upgrade --install keda kedacore/keda --namespace keda --create-namespace --wait
kubectl annotate serviceaccount keda-operator -n keda \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw keda_operator_role_arn)
AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id) \
  envsubst < keda-scaledobject.yaml | kubectl apply -f -

# Karpenter
CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)
CLUSTER_ENDPOINT=$(terraform -chdir=terraform output -raw cluster_endpoint)
KARPENTER_ROLE_ARN=$(terraform -chdir=terraform output -raw karpenter_controller_role_arn)

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.3.3 \
  --namespace karpenter --create-namespace --wait \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_ROLE_ARN \
  --set settings.clusterName=$CLUSTER_NAME \
  --set settings.clusterEndpoint=$CLUSTER_ENDPOINT \
  --set settings.interruptionQueue=KarpenterInterruption-$CLUSTER_NAME

CLUSTER_NAME=$CLUSTER_NAME envsubst < karpenter-nodepool.yaml | kubectl apply -f -
```

---

## 최종 상태 확인

```bash
kubectl get pods -A
```

정상 상태:

```
NAMESPACE     NAME                                  READY   STATUS
default       redis-xxx                             1/1     Running
default       concert-frontend-xxx                  1/1     Running
default       concert-worker-xxx                    1/1     Running
default       aws-infra-setup-xxx                   0/1     Completed
keda          keda-operator-xxx                     1/1     Running
keda          keda-admission-webhooks-xxx           1/1     Running
keda          keda-operator-metrics-apiserver-xxx   1/1     Running
karpenter     karpenter-xxx                         1/1     Running
```

LoadBalancer URL 확인:

```bash
kubectl get svc concert-frontend-svc
```

---

## 트러블슈팅

**`kubectl get nodes` → credentials 에러**
→ Access Entry 미등록. [2단계](#2-kubeconfig-업데이트) 참고.

**concert-frontend/worker 파드가 없음**
→ `worker-sa` ServiceAccount 미생성. [3단계](#3-worker-sa-serviceaccount-생성-및-irsa-연결) 참고.

**파드가 Pending 상태**
```bash
kubectl describe pod <pod-name>
```
→ `0/4 nodes are available` 메시지면 노드 리소스 부족. app-nodes 노드그룹 스케일 업 필요.

**keda-scaledobject.yaml / karpenter-nodepool.yaml apply 실패 (no matches for kind)**
→ CRD 미설치. KEDA/Karpenter Helm 설치 전에 yaml을 먼저 적용한 경우. `bash deploy.sh` 순서대로 실행.

**SQS URL 관련 에러**
→ `envsubst` 없이 `kubectl apply -f` 직접 실행한 경우. `${AWS_ACCOUNT_ID}` 플레이스홀더가 그대로 들어감. 반드시 envsubst 파이프 사용.

---

## DynamoDB 스키마

테이블명: `modo-coupon-claims`

| 필드 | 타입 | 설명 |
|------|------|------|
| `request_id` | String (PK) | 클릭 시 생성되는 UUID |
| `status` | String | `winner` / `loser` |
| `coupon_code` | String | 발급된 쿠폰 코드 (당첨자만) |
| `claimed_at` | String | 처리 ISO 타임스탬프 |
| `email` | String | 당첨자 이메일 |
| `email_sent` | Boolean | SES 발송 완료 여부 |

## PriorityClass

| 클래스 | 값 | 대상 | 설명 |
|--------|---|------|------|
| `modo-critical` | 100,000 | Redis | 절대 선점 불가 |
| `modo-high` | 10,000 | Frontend | 트래픽 스파이크 시에도 항상 보장 |
| `modo-normal` | 1,000 | Worker | 리소스 부족 시 선점 허용 |

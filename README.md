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
| concert-frontend | 쇼핑몰 UI + API 서버 (메인/이벤트/관리자 페이지) | Flask + Gunicorn |
| concert-worker | SQS 메시지 소비 → 쿠폰 당첨/낙첨 판정 | Python + boto3 |
| Redis | 실시간 티켓 카운터 + 결과 임시 저장 | Redis Alpine |
| DynamoDB | 쿠폰 발급 이력 영구 저장 | AWS DynamoDB (PAY_PER_REQUEST) |
| SES | 당첨자 쿠폰 이메일 발송 | AWS SES |
| KEDA | SQS 큐 깊이 기반 Worker 자동 스케일링 (1~50) | KEDA v2 |
| Karpenter | 부하 시 EC2 Spot 노드 자동 프로비저닝/제거 | Karpenter v1.1.1 |

---

## 파일 구조

```
.
├── terraform/                  # AWS 인프라 (EKS, VPC, IAM, DynamoDB, SQS)
│   ├── main.tf                 # Provider 설정
│   ├── variables.tf            # 변수 (cluster_name, account_id, region 등)
│   ├── vpc.tf                  # VPC, 서브넷, 라우팅
│   ├── eks.tf                  # EKS 클러스터, 노드그룹, 애드온, OIDC
│   ├── iam.tf                  # IAM Role/Policy (Worker, KEDA, Karpenter)
│   ├── dynamodb.tf             # DynamoDB 쿠폰 클레임 테이블
│   └── outputs.tf              # 배포 후 참조값 출력 + next_steps 안내
│
├── app-deployment.yaml         # K8s 리소스 (PriorityClass, RBAC, ConfigMap, Deployment, Service)
├── configmap-code.yaml         # Python 코드 (app.py, worker.py, setup.py)
├── configmap-html.yaml         # HTML 페이지 (main.html, event.html, admin.html)
├── redis.yaml                  # Redis Deployment + Service
├── karpenter-nodepool.yaml     # Karpenter EC2NodeClass + NodePool
└── keda-scaledobject.yaml      # KEDA ScaledObject + TriggerAuthentication
```

---

## 배포 순서

### 사전 준비

```bash
# variables.tf에서 본인 환경에 맞게 수정
# - account_id: 본인 AWS 계정 ID
# - sender_email: SES에서 인증된 이메일
```

### 1. Terraform으로 인프라 생성 (20~30분 소요)

```bash
cd terraform
terraform init
terraform apply
```

생성되는 리소스: VPC, EKS 클러스터(y2ks-eks-cluster), 노드그룹, IAM Role/Policy, DynamoDB 테이블, Karpenter SQS 큐

### 2. kubectl 연결

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name y2ks-eks-cluster
kubectl get nodes  # 노드 확인
```

### 3. EKS 접근 권한 추가 (팀원 각자 실행)

```bash
aws eks create-access-entry \
  --cluster-name y2ks-eks-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<IAM_USERNAME> \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name y2ks-eks-cluster \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:user/<IAM_USERNAME> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

### 4. worker-sa ServiceAccount 생성

```bash
kubectl create serviceaccount worker-sa
kubectl annotate serviceaccount worker-sa \
  eks.amazonaws.com/role-arn=$(cd terraform && terraform output -raw worker_role_arn)
```

### 5. 앱 배포

```bash
kubectl apply -f redis.yaml
kubectl apply -f configmap-code.yaml
kubectl apply -f configmap-html.yaml
kubectl apply -f app-deployment.yaml

kubectl get pods -w  # 파드 상태 확인
```

### 6. KEDA 설치

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace

kubectl annotate serviceaccount keda-operator -n keda \
  eks.amazonaws.com/role-arn=$(cd terraform && terraform output -raw keda_operator_role_arn)

kubectl apply -f keda-scaledobject.yaml
```

### 7. Karpenter 설치

```bash
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name y2ks-eks-cluster \
  --query 'cluster.endpoint' --output text)

helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.1.1 \
  --namespace karpenter --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(cd terraform && terraform output -raw karpenter_controller_role_arn) \
  --set settings.clusterName=y2ks-eks-cluster \
  --set settings.clusterEndpoint=$CLUSTER_ENDPOINT \
  --set settings.interruptionQueue=KarpenterInterruption-y2ks-eks-cluster

kubectl apply -f karpenter-nodepool.yaml
```

### 8. 접속 URL 확인

```bash
kubectl get svc concert-frontend-svc
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

---

## 클러스터 삭제

```bash
helm uninstall karpenter -n karpenter
helm uninstall keda -n keda
cd terraform && terraform destroy
```

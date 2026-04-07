# Y2KS Fashion - EKS 쿠폰 이벤트 시스템

고트래픽 선착순 쿠폰 이벤트를 AWS EKS 위에서 운영하는 패션 쇼핑몰 시스템입니다.
KEDA + Karpenter로 정각 트래픽 스파이크를 자동 대응합니다.

---

## 아키텍처

```
[사용자]
   |
   v
[쇼핑몰 메인 /]  ->  [이벤트 페이지 /event]
                              |
                        버튼 클릭
                              |
                    [Flask API /api/claim]
                              |
                         [SQS Queue]  <--- KEDA가 메시지 수 감지
                              |                    |
                        [Worker Pod]  ---------- Scale Out
                              |            (Karpenter -> EC2 Spot 노드 추가)
                   +----------+-----------+
                   |                      |
               당첨 (Redis)           낙첨 (Redis)
                   |                      |
             [DynamoDB 기록]        [DynamoDB 기록]
                   |
         이메일 입력 -> SES 발송
```

---

## 구성 요소

| 서비스 | 역할 | 기술 |
|--------|------|------|
| y2ks-frontend | 쇼핑몰 UI + Flask API | Python 3.9 + gunicorn |
| y2ks-worker | SQS 메시지 소비, 당첨/낙첨 처리 | Python 3.9 + boto3 |
| Redis | 실시간 티켓 수량 및 결과 임시 저장 | Redis Alpine |
| DynamoDB | 쿠폰 발급 이력 영구 저장 | AWS DynamoDB (PAY_PER_REQUEST) |
| SES | 당첨자 쿠폰 이메일 발송 | AWS SES |
| KEDA | SQS 메시지 수 기반 Worker 자동 스케일링 | KEDA v2 |
| Karpenter | 부하 시 EC2 Spot 노드 자동 추가/제거 | Karpenter v1 |

---

## 파일 구조

```
.
+-- terraform/
|   +-- main.tf             # Provider, aws_caller_identity (계정 ID 자동 감지)
|   +-- variables.tf        # 클러스터명, 리전, k8s 버전, 발신 이메일
|   +-- vpc.tf              # VPC, 퍼블릭 서브넷 3개, IGW
|   +-- eks.tf              # EKS 클러스터, 노드그룹 2개, OIDC, Access Entry
|   +-- iam.tf              # Worker / KEDA / Karpenter IAM Role + Policy
|   +-- dynamodb.tf         # DynamoDB 테이블 (y2ks-coupon-claims)
|   +-- outputs.tf          # ARN, URL, 클러스터 정보 출력
+-- app-deployment.yaml     # PriorityClass, RBAC, ConfigMap, Deployment, Service
+-- redis.yaml              # Redis Deployment + ClusterIP Service
+-- keda-scaledobject.yaml  # KEDA ScaledObject + TriggerAuthentication
+-- karpenter-nodepool.yaml # EC2NodeClass + NodePool
+-- deploy.sh               # KEDA/Karpenter Helm 설치 + yaml 적용 자동화
```

---

## 사전 요구사항

- AWS CLI - `aws configure` 완료
- Terraform >= 1.5
- kubectl
- helm
- envsubst (`gettext` 패키지)

---

## 배포 순서

```
[1] terraform apply             AWS 인프라 전체 생성
      |
[2] aws eks update-kubeconfig   클러스터 접근 설정
      |
[3] kubectl create serviceaccount worker-sa + IRSA 연결
      |
[4] kubectl apply -f redis.yaml
      |
[5] envsubst | kubectl apply -f app-deployment.yaml
      |
[6] bash deploy.sh              KEDA + Karpenter 설치 및 yaml 적용
```

---

### 1. Terraform - AWS 인프라 생성

```bash
cd terraform
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply --auto-approve
```

생성 리소스:

| 리소스 | 내용 |
|--------|------|
| VPC | 192.168.0.0/16, 퍼블릭 서브넷 3개 (AZ별) |
| EKS | v1.31, authentication_mode: API_AND_CONFIG_MAP |
| 노드그룹 | standard-nodes (t3.micro x2), app-nodes (t3.small x2) |
| IAM Role | Y2ksWorkerRole, KedaOperatorRole, KarpenterControllerRole, KarpenterNodeRole |
| DynamoDB | y2ks-coupon-claims (PAY_PER_REQUEST) |
| SQS | KarpenterInterruption-{cluster_name} (Spot 인터럽트 알림용), y2ks-queue (부하테스트용)|
| Access Entry | 현재 `aws configure` 사용자를 클러스터 admin으로 자동 등록 |

> account ID는 `aws configure`에 설정된 값을 자동으로 읽습니다. 하드코딩 없음.

---

### 2. EKS - kubeconfig 업데이트

```bash
cd ..  # terraform/ 에서 프로젝트 루트로 이동
aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name $(terraform -chdir=terraform output -raw cluster_name)

kubectl get nodes   # 노드 4개 확인
```

---

### 3. Kubernetes - worker-sa ServiceAccount 생성 및 IRSA 연결

```bash
kubectl create serviceaccount worker-sa

kubectl annotate serviceaccount worker-sa \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw worker_role_arn)
```

---

### 4. Kubernetes - Redis 배포

```bash
kubectl apply -f redis.yaml
```

---

### 5. Kubernetes - 앱 배포

`app-deployment.yaml`에는 `${AWS_ACCOUNT_ID}` 플레이스홀더가 있습니다.
`envsubst`로 치환 후 적용합니다.

```bash
export AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id)

envsubst < app-deployment.yaml | kubectl apply -f -
```

배포 확인:

```bash
kubectl get pods
# y2ks-frontend-xxx   1/1   Running
# y2ks-worker-xxx     1/1   Running
# aws-infra-setup-xxx 0/1   Completed   <- SQS 큐/DynamoDB 자동 생성 Job

kubectl get svc y2ks-frontend-svc
# EXTERNAL-IP 에 LoadBalancer URL이 나타날 때까지 1~2분 대기
```

---

### 6. Helm + Kubernetes - KEDA / Karpenter 설치

```bash
bash deploy.sh
```

`deploy.sh` 내부 흐름:

```
helm install keda                          KEDA 컨트롤러 설치
  +- kubectl annotate keda-operator        IRSA 연결
  +- envsubst | kubectl apply              keda-scaledobject.yaml 적용

aws ecr-public get-login-password          ECR Public 인증 (us-east-1 필수)
  +- helm registry login public.ecr.aws
helm install karpenter                     Karpenter 컨트롤러 설치
  +- envsubst | kubectl apply              karpenter-nodepool.yaml 적용
```

---

## 최종 상태 확인

```bash
kubectl get pods -A
```

```
NAMESPACE     NAME                                    READY   STATUS
default       redis-xxx                               1/1     Running
default       y2ks-frontend-xxx                       1/1     Running
default       y2ks-worker-xxx                         1/1     Running
default       aws-infra-setup-xxx                     0/1     Completed
keda          keda-operator-xxx                       1/1     Running
keda          keda-admission-webhooks-xxx             1/1     Running
keda          keda-operator-metrics-apiserver-xxx     1/1     Running
karpenter     karpenter-xxx                           1/1     Running
```

```bash
kubectl get svc y2ks-frontend-svc
# EXTERNAL-IP 값이 접속 URL
```

---

## 리소스 삭제

Helm과 kubectl로 생성한 리소스를 먼저 제거한 뒤 Terraform으로 AWS 인프라를 삭제합니다.
순서를 지키지 않으면 LoadBalancer, 노드 등이 VPC에 남아 `terraform destroy`가 실패합니다.

```
[1] Karpenter NodePool / EC2NodeClass 제거 (finalizer 강제 해제)
      |
[2] KEDA ScaledObject 제거
      |
[3] 앱 / Redis 제거 (LoadBalancer 포함)
      |
[4] helm uninstall keda / karpenter
      |
[5] terraform destroy
```

### 1. Karpenter NodePool / EC2NodeClass 제거

EC2NodeClass는 Karpenter가 finalizer를 붙여놓기 때문에 단순 `kubectl delete`로는 삭제가 멈춥니다.
Karpenter 컨트롤러가 정상 동작하지 않는 상태라면 finalizer를 강제로 제거해야 합니다.

```bash
 
kubectl delete ec2nodeclass default --ignore-not-found
# 만약 위 명령어가 오래 걸리는 경우 ctrl + c 로 취소 한 뒤에 아래 finalizer 제거 후 다시 시도

# finalizer 강제 제거 후 삭제
kubectl patch ec2nodeclass default --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'

kubectl delete nodepool default --ignore-not-found
```

### 2. KEDA ScaledObject 제거

```bash
export AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id)
envsubst < keda-scaledobject.yaml | kubectl delete -f -
```

### 3. 앱 / Redis 제거

```bash
# LoadBalancer Service 포함 삭제 (terraform destroy 전에 반드시 먼저 제거)
envsubst < app-deployment.yaml | kubectl delete -f -
kubectl delete -f redis.yaml
kubectl delete serviceaccount worker-sa
```

> LoadBalancer가 완전히 삭제될 때까지 1~2분 대기 후 다음 단계로 진행하세요.
> `kubectl get svc y2ks-frontend-svc` 로 삭제 완료 확인.

### 4. Helm - KEDA / Karpenter 제거

```bash
helm uninstall keda -n keda
helm uninstall karpenter -n karpenter

kubectl delete namespace keda
kubectl delete namespace karpenter
```

### 5. Terraform - AWS 인프라 삭제

```bash
cd terraform
terraform destroy --auto-approve
```

> `terraform destroy` 중 VPC 삭제 실패 시 AWS 콘솔에서 ENI(Elastic Network Interface)가 남아있는지 확인하세요.

---

## 부록

### DynamoDB 스키마 - y2ks-coupon-claims

| 필드 | 타입 | 설명 |
|------|------|------|
| `request_id` | String (PK) | 버튼 클릭 시 생성되는 UUID |
| `status` | String | `winner` / `loser` |
| `coupon_code` | String | 발급된 쿠폰 코드 (당첨자만) |
| `claimed_at` | String | 처리 ISO 타임스탬프 |
| `email` | String | 당첨자 이메일 |
| `email_sent` | Boolean | SES 발송 완료 여부 |

### PriorityClass

| 클래스 | 값 | 대상 | 설명 |
|--------|---|------|------|
| `y2ks-critical` | 100,000 | Redis | 절대 선점 불가 |
| `y2ks-high` | 10,000 | Frontend | 트래픽 스파이크 시에도 항상 보장 |
| `y2ks-normal` | 1,000 | Worker | 리소스 부족 시 선점 허용 |
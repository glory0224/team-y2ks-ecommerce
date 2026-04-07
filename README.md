# Y2KS Fashion - EKS Coupon Event System

High-traffic first-come-first-served coupon even system running on AWS EKS.
KEDA + Karpenter handle automatic scaling for traffic spikes.

---

## Architecture

```
[User]
   │
   ▼
[Shop Main /]  →  [Event Page /event]
                              │
                        Button click
                              │
                    [Flask API /api/claim]
                              │
                         [SQS Queue]  ←── KEDA monitors message count
                              │                    │
                        [Worker Pod]  ──────── Scale Out
                              │            (Karpenter → add EC2 Spot nodes)
                   ┌──────────┴──────────┐
                   │                     │
               Winner (Redis)        Loser (Redis)
                   │                     │
             [DynamoDB record]     [DynamoDB record]
                   │
         Email input → SES send
```

---

## Components

| Service | Role | Stack |
|---------|------|-------|
| y2ks-frontend | Shop UI + Flask API | Python 3.9 + gunicorn |
| y2ks-worker | SQS consumer, winner/loser processing | Python 3.9 + boto3 |
| Redis | Real-time ticket count and result cache | Redis Alpine |
| DynamoDB | Permanent coupon issuance records | AWS DynamoDB (PAY_PER_REQUEST) |
| SES | Winner coupon email delivery | AWS SES |
| KEDA | Auto-scale worker based on SQS message count | KEDA v2 |
| Karpenter | Add/remove EC2 Spot nodes under load | Karpenter v1 |

---

## File Structure

```
.
├── terraform/
│   ├── main.tf             # Provider, aws_caller_identity (auto-detects account ID)
│   ├── variables.tf        # Cluster name, region, k8s version, sender email
│   ├── vpc.tf              # VPC, 3 public subnets, IGW
│   ├── eks.tf              # EKS cluster, 2 node groups, OIDC, Access Entry
│   ├── iam.tf              # Worker / KEDA / Karpenter IAM Role + Policy
│   ├── dynamodb.tf         # DynamoDB table (y2ks-coupon-claims)
│   └── outputs.tf          # ARN, URL, cluster info outputs
├── app-deployment.yaml     # PriorityClass, RBAC, ConfigMap, Deployment, Service
├── redis.yaml              # Redis Deployment + ClusterIP Service
├── keda-scaledobject.yaml  # KEDA ScaledObject + TriggerAuthentication
├── karpenter-nodepool.yaml # EC2NodeClass + NodePool
└── deploy.sh               # KEDA/Karpenter Helm install + yaml apply automation
```

---

## Prerequisites

- AWS CLI — `aws configure` completed
- Terraform >= 1.5
- kubectl
- helm
- envsubst (`gettext` package)

---

## Deployment Order

```
[1] terraform apply             Create all AWS infrastructure
      │
[2] aws eks update-kubeconfig   Configure cluster access
      │
[3] kubectl create serviceaccount worker-sa + IRSA annotation
      │
[4] kubectl apply -f redis.yaml
      │
[5] envsubst | kubectl apply -f app-deployment.yaml
      │
[6] bash deploy.sh              Install KEDA + Karpenter and apply yamls
```

---

### 1. Terraform — Create AWS Infrastructure

```bash
cd terraform
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply --auto-approve
```

Resources created:

| Resource | Details |
|----------|---------|
| VPC | 192.168.0.0/16, 3 public subnets (per AZ) |
| EKS | v1.31, authentication_mode: API_AND_CONFIG_MAP |
| Node Groups | standard-nodes (t3.micro x2), app-nodes (t3.small x2) |
| IAM Roles | Y2ksWorkerRole, KedaOperatorRole, KarpenterControllerRole, KarpenterNodeRole |
| DynamoDB | y2ks-coupon-claims (PAY_PER_REQUEST) |
| SQS | KarpenterInterruption-{cluster_name} (Spot interruption notifications) |
| Access Entry | Current `aws configure` user auto-registered as cluster admin |

> Account ID is read automatically from `aws configure`. No hardcoding.

---

### 2. EKS — Update kubeconfig

```bash
cd ..  # back to project root from terraform/
aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name $(terraform -chdir=terraform output -raw cluster_name)

kubectl get nodes   # expect 4 nodes
```

---

### 3. Kubernetes — Create worker-sa ServiceAccount and attach IRSA

```bash
kubectl create serviceaccount worker-sa

kubectl annotate serviceaccount worker-sa \
  eks.amazonaws.com/role-arn=$(terraform -chdir=terraform output -raw worker_role_arn)
```

---

### 4. Kubernetes — Deploy Redis

```bash
kubectl apply -f redis.yaml
```

---

### 5. Kubernetes — Deploy App

`app-deployment.yaml` contains `${AWS_ACCOUNT_ID}` placeholder.
Use `envsubst` to substefore applying.

```bash
export AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id)

envsubst < app-deployment.yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get pods
# y2ks-frontend-xxx   1/1   Running
# y2ks-worker-xxx     1/1   Running
# aws-infra-setup-xxx 0/1   Completed   ← auto-creates SQS queue and DynamoDB table

kubectl get svc y2ks-frontend-svc
# Wait 1-2 min for EXTERNAL-IP to appear (LoadBalancer URL)
```

---

### 6. Helm + Kubernetes — Install KEDA / Karpenter

```bash
bash deploy.sh
```

`deploy.sh` flow:

```
helm install keda                          Install KEDA controller
  └─ kubectl annotate keda-operator        Attach IRSA
  └─ envsubst | kubectl apply              Apply keda-scaledobject.yaml

aws ecr-public get-login-password          Authenticate ECR Public (us-east-1 required)
  └─ helm registry login public.ecr.aws
helm install karpenter                     Install Karpenter controller
  └─ envsubst | kubectl apply              Apply karpenter-nodepool.yaml
```

---

## Final State Check

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
# EXTERNAL-IP is the access URL
```

---

## Teardown

Remove Helm and kubectl resources first, then destroy Terraform infrastructure.
Skipping this order will leave LoadBalancers and nodes in the VPC, causing `terraform destroy` to fail.

```
[1] kubectl delete          Remove app / Redis / KEDA CRDs
      │
[2] helm uninstall keda     Remove KEDA controller
      │
[3] helm uninstall karpenter   Remove Karpenter controller
      │
[4] terraform destroy       Destroy all AWS infrastructure
```

### 1. Remove Kubernetes Resources

```bash
# Remove KEDA ScaledObject and Karpenter NodePool
export AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id)
export CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)

envsubst < keda-scaledobject.yaml | kubectl delete -f -
envsubst < karpenter-nodepool.yaml | kubectl delete -f -

# Remove app and Redis (includes LoadBalancer Service)
l delete -f -
kubectl delete -f redis.yaml

# Remove worker-sa ServiceAccount
kubectl delete serviceaccount worker-sa
```

### 2. Helm — Uninstall KEDA / Karpenter

```bash
helm uninstall keda -n keda
helm uninstall karpenter -n karpenter

kubectl delete namespace keda
kubectl delete namespace karpenter
```

### 3. Terraform — Destroy AWS Infrastructure

```bash
cd terraform
terraform destroy
```

> LoadBalancer deletion may take a few minutes.
> IENIs (Elastic Network Interfaces) in the AWS console.

---

## Appendix

### DynamoDB Schema — y2ks-coupon-claims

| Field | Type | Description |
|-------|------|-------------|
| `request_id` | String (PK) | UUID generated on button click |
| `status` | String | `winner` / `loser` |
| `coupon_code` | String | Issued coupon code (winners only) |
| `claimed_at` | String | ISO timestamp of processing |
| `email` | String | Winner email address |
| `email_sent` | Boolean | Whether SES email was sent |

### PriorityClass

| Class | Value | Target | Description |
|-------|-------|--------|-------------|
| `y2ks-critical` | 100,000 | Redis | Never preempted |
| `y2ks-high` | 10,000 | Frontend | Guaranteed even during traffic spikes |
| `y2ks-normal` | 1,000 | Worker | Preemptible when resources are scarce |

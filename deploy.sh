#!/bin/bash
# Deployment script: installs Helm charts and applies yaml manifests
# Usage: bash deploy.sh

set -e

# Read values from terraform output
export AWS_ACCOUNT_ID=$(terraform -chdir=terraform output -raw account_id)
export CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)
export KARPENTER_ROLE_ARN=$(terraform -chdir=terraform output -raw karpenter_controller_role_arn)
export KEDA_ROLE_ARN=$(terraform -chdir=terraform output -raw keda_operator_role_arn)
export CLUSTER_ENDPOINT=$(terraform -chdir=terraform output -raw cluster_endpoint)

echo "Account: $AWS_ACCOUNT_ID | Cluster: $CLUSTER_NAME"

# ── KEDA ──────────────────────────────────────────────
echo "[1/4] Installing KEDA..."
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace --wait

kubectl annotate serviceaccount keda-operator -n keda --overwrite \
  eks.amazonaws.com/role-arn=$KEDA_ROLE_ARN

echo "[2/4] Applying keda-scaledobject.yaml..."
envsubst < keda-scaledobject.yaml | kubectl apply -f -

# ── Karpenter ─────────────────────────────────────────
echo "[3/4] Installing Karpenter..."
# ECR Public registry requires authentication against us-east-1
aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.3.3 \
  --namespace karpenter --create-namespace --wait \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_ROLE_ARN \
  --set settings.clusterName=$CLUSTER_NAME \
  --set settings.clusterEndpoint=$CLUSTER_ENDPOINT \
  --set settings.interruptionQueue=KarpenterInterruption-$CLUSTER_NAME

echo "[4/4] Applying karpenter-nodepool.yaml..."
envsubst < karpenter-nodepool.yaml | kubectl apply -f -

echo "Done."

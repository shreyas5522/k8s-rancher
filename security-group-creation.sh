#!/usr/bin/env bash
set -e

VPC_ID="$1"
AWS_REGION="us-east-2"

if [ -z "$VPC_ID" ]; then
  echo "Usage: $0 <vpc-id>"
  exit 1
fi

echo "Region : $AWS_REGION"
echo "VPC    : $VPC_ID"
echo

# -----------------------------
# Get or create Control Plane SG
# -----------------------------
CP_SG_ID=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values=k8s-control-plane-sg \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [ "$CP_SG_ID" = "None" ]; then
  CP_SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --vpc-id "$VPC_ID" \
    --group-name k8s-control-plane-sg \
    --description "Kubernetes Control Plane SG" \
    --query 'GroupId' \
    --output text)
  echo "Created Control Plane SG: $CP_SG_ID"
else
  echo "Using existing Control Plane SG: $CP_SG_ID"
fi

# -----------------------------
# Get or create Worker SG
# -----------------------------
WK_SG_ID=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values=k8s-worker-sg \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [ "$WK_SG_ID" = "None" ]; then
  WK_SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --vpc-id "$VPC_ID" \
    --group-name k8s-worker-sg \
    --description "Kubernetes Worker SG" \
    --query 'GroupId' \
    --output text)
  echo "Created Worker SG: $WK_SG_ID"
else
  echo "Using existing Worker SG: $WK_SG_ID"
fi

# -----------------------------
# Egress allow all
# -----------------------------
for SG in "$CP_SG_ID" "$WK_SG_ID"; do
  aws ec2 authorize-security-group-egress \
    --region "$AWS_REGION" \
    --group-id "$SG" \
    --protocol -1 \
    --cidr 0.0.0.0/0 2>/dev/null || true
done

# -----------------------------
# Control Plane ingress
# -----------------------------
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$CP_SG_ID" \
  --protocol tcp --port 6443 \
  --source-group "$WK_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$CP_SG_ID" \
  --protocol tcp --port 9345 \
  --source-group "$WK_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$CP_SG_ID" \
  --protocol tcp --port 2379-2380 \
  --source-group "$CP_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$CP_SG_ID" \
  --protocol tcp --port 10250 \
  --source-group "$CP_SG_ID" 2>/dev/null || true

# -----------------------------
# Worker ingress
# -----------------------------
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$WK_SG_ID" \
  --protocol tcp --port 6443 \
  --source-group "$CP_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$WK_SG_ID" \
  --protocol tcp --port 9345 \
  --source-group "$CP_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$WK_SG_ID" \
  --protocol tcp --port 10250 \
  --source-group "$WK_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$WK_SG_ID" \
  --protocol udp --port 8472 \
  --source-group "$WK_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$WK_SG_ID" \
  --protocol tcp --port 30000-32767 \
  --source-group "$WK_SG_ID" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$WK_SG_ID" \
  --protocol udp --port 30000-32767 \
  --source-group "$WK_SG_ID" 2>/dev/null || true

echo
echo "✅ Security groups ready"
echo "Control Plane SG : $CP_SG_ID"
echo "Worker SG        : $WK_SG_ID"

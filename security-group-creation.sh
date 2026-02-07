#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Configurable defaults
# ---------------------------
DEFAULT_REGION="us-east-2"
DEFAULT_SSH_CIDR="0.0.0.0/0"   # Recommend restricting this to your IP
CP_SG_NAME="k8s-control-plane-sg"
WK_SG_NAME="k8s-worker-sg"

CP_SG_DESC="Kubernetes Control Plane SG: API Server (6443), etcd (2379-2380), kubelet (10250), internal/overlay networking"
WK_SG_DESC="Kubernetes Worker Node SG: kubelet (10250), NodePort (30000-32767), overlay networking (VXLAN/Flannel/Cilium)"

echo "==============================================" >&2
echo " Kubernetes Security Group Setup Script" >&2
echo "==============================================" >&2

# ---------------------------
# Prompts
# ---------------------------
# Allow overriding via env vars, otherwise prompt
if [[ -z "${REGION:-}" ]]; then
    read -rp "Enter AWS Region [${DEFAULT_REGION}]: " REGION
    REGION="${REGION:-$DEFAULT_REGION}"
fi

if [[ -z "${VPC_ID:-}" ]]; then
    read -rp "Enter VPC ID (e.g. vpc-xxxxxxxx): " VPC_ID
fi

if [[ -z "$VPC_ID" ]]; then
  echo "❌ Error: VPC ID cannot be empty." >&2
  exit 1
fi

if [[ -z "${SSH_CIDR:-}" ]]; then
    read -rp "Enter SSH allowed CIDR [${DEFAULT_SSH_CIDR}]: " SSH_CIDR
    SSH_CIDR="${SSH_CIDR:-$DEFAULT_SSH_CIDR}"
fi

echo "" >&2
echo "Using Configuration:" >&2
echo "  Region   : $REGION" >&2
echo "  VPC ID   : $VPC_ID" >&2
echo "  SSH CIDR : $SSH_CIDR" >&2
echo "" >&2

# ---------------------------
# Helper functions
# ---------------------------

get_sg_id_by_name() {
  local name="$1"
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --region "$REGION" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true
}

validate_sg_id() {
  local sg_id="$1"
  [[ "$sg_id" =~ ^sg-[0-9a-f]{8,}$ ]]
}

create_sg_if_missing() {
  local name="$1"
  local desc="$2"
  local sg_id

  sg_id="$(get_sg_id_by_name "$name")"

  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    echo "🆕 Creating security group: $name" >&2
    sg_id="$(aws ec2 create-security-group \
      --group-name "$name" \
      --description "$desc" \
      --vpc-id "$VPC_ID" \
      --region "$REGION" \
      --query 'GroupId' \
      --output text)"
    echo "   -> Created: $sg_id" >&2
  else
    echo "ℹ️  Security group already exists: $name ($sg_id)" >&2
  fi

  # Tag for clarity in UI
  aws ec2 create-tags --resources "$sg_id" --region "$REGION" \
    --tags "Key=Name,Value=$name" "Key=Description,Value=$desc" >/dev/null 2>&1 || true

  # Echo ONLY the ID to STDOUT
  echo "$sg_id"
}

# Adds a single ingress rule
add_ingress_rule() {
  local sg_id="$1"
  local proto="$2"
  local port_spec="$3"    # single port (80) or range (30000-32767)
  local src_type="$4"     # "cidr" or "sg"
  local src_val="$5"

  # Construct base arguments
  local args=(--group-id "$sg_id" --protocol "$proto" --region "$REGION")

  # Only add --port if protocol is NOT 'all' or '-1'
  if [[ "$proto" != "-1" && "$proto" != "all" ]]; then
      args+=(--port "$port_spec")
  fi

  # Add source arguments
  if [[ "$src_type" == "cidr" ]]; then
    args+=(--cidr "$src_val")
  else
    args+=(--source-group "$src_val")
  fi

  # Execute and capture output/error
  if output=$(aws ec2 authorize-security-group-ingress "${args[@]}" 2>&1); then
    echo "   ✅ Added: proto=$proto port=$port_spec from $src_type=$src_val" >&2
  else
    # Check for Duplicate error (Idempotency)
    if echo "$output" | grep -qE "InvalidPermission.Duplicate|InvalidGroup.Duplicate"; then
      echo "   ⚠️  Exists: proto=$proto port=$port_spec from $src_type=$src_val" >&2
    else
      echo "   ❌ Error adding rule: proto=$proto port=$port_spec from $src_type=$src_val" >&2
      echo "      AWS output: $output" >&2
      exit 1
    fi
  fi
}

allow_egress_all() {
  local sg_id="$1"
  # Attempt to revoke default egress if needed (optional, usually not needed if creating fresh)
  # But we will just ensure Allow All exists.
  
  local args=(--group-id "$sg_id" --protocol "-1" --cidr "0.0.0.0/0" --region "$REGION")

  if output=$(aws ec2 authorize-security-group-egress "${args[@]}" 2>&1); then
    echo "   ✅ Egress: allow all (0.0.0.0/0)" >&2
  else
    if echo "$output" | grep -qE "InvalidPermission.Duplicate"; then
      echo "   ⚠️  Egress already allows all" >&2
    else
      echo "   ❌ Error setting egress: $output" >&2
      exit 1
    fi
  fi
}

# ---------------------------
# Execution
# ---------------------------

echo "🚀 Ensuring Security Groups exist..." >&2
CONTROL_PLANE_SG_ID="$(create_sg_if_missing "$CP_SG_NAME" "$CP_SG_DESC")"
WORKER_SG_ID="$(create_sg_if_missing "$WK_SG_NAME" "$WK_SG_DESC")"

# Validate IDs
if ! validate_sg_id "$CONTROL_PLANE_SG_ID"; then
  echo "❌ Control Plane SG ID malformed: '$CONTROL_PLANE_SG_ID'" >&2
  exit 1
fi
if ! validate_sg_id "$WORKER_SG_ID"; then
  echo "❌ Worker SG ID malformed: '$WORKER_SG_ID'" >&2
  exit 1
fi

# Give AWS a moment to propagate existence before adding rules
sleep 2

# ---------------------------
# Ingress: Control Plane
# ---------------------------
echo "" >&2
echo "🔐 Configuring INGRESS rules (Control Plane: $CONTROL_PLANE_SG_ID)..." >&2

# External Access
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 6443 cidr "0.0.0.0/0"     # Kubernetes API (External) - CAREFUL: Limit this in prod!
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 22   cidr "$SSH_CIDR"     # SSH
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 80   cidr "0.0.0.0/0"     # HTTP
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 443  cidr "0.0.0.0/0"     # HTTPS

# From Worker Nodes
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 6443 sg "$WORKER_SG_ID"   # API server
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 9345 sg "$WORKER_SG_ID"   # RKE2/Cluster API
add_ingress_rule "$CONTROL_PLANE_SG_ID" udp 4789 sg "$WORKER_SG_ID"   # VXLAN Overlay

# From Control Plane (Self)
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 2379-2380 sg "$CONTROL_PLANE_SG_ID" # Etcd
add_ingress_rule "$CONTROL_PLANE_SG_ID" tcp 10250     sg "$CONTROL_PLANE_SG_ID" # Kubelet
add_ingress_rule "$CONTROL_PLANE_SG_ID" udp 4789      sg "$CONTROL_PLANE_SG_ID" # Overlay Self

# ---------------------------
# Ingress: Worker
# ---------------------------
echo "" >&2
echo "🔐 Configuring INGRESS rules (Worker: $WORKER_SG_ID)..." >&2

# NodePorts (External)
add_ingress_rule "$WORKER_SG_ID" tcp 30000-32767 cidr "0.0.0.0/0"
add_ingress_rule "$WORKER_SG_ID" udp 30000-32767 cidr "0.0.0.0/0"

# SSH
add_ingress_rule "$WORKER_SG_ID" tcp 22  cidr "$SSH_CIDR"

# From Control Plane
add_ingress_rule "$WORKER_SG_ID" tcp 10250 sg "$CONTROL_PLANE_SG_ID" # Kubelet API
add_ingress_rule "$WORKER_SG_ID" udp 4789  sg "$CONTROL_PLANE_SG_ID" # Overlay
add_ingress_rule "$WORKER_SG_ID" tcp 9345  sg "$CONTROL_PLANE_SG_ID" # Cluster API

# From Worker (Self)
add_ingress_rule "$WORKER_SG_ID" tcp 10250 sg "$WORKER_SG_ID"        # Kubelet Self
add_ingress_rule "$WORKER_SG_ID" udp 4789  sg "$WORKER_SG_ID"        # Overlay Self
add_ingress_rule "$WORKER_SG_ID" udp 8472  sg "$WORKER_SG_ID"        # Flannel (if used)

# ---------------------------
# Egress
# ---------------------------
echo "" >&2
echo "🌐 Configuring EGRESS rules..." >&2
allow_egress_all "$CONTROL_PLANE_SG_ID"
allow_egress_all "$WORKER_SG_ID"

# ---------------------------
# Summary
# ---------------------------
echo "" >&2
echo "✅✅ Kubernetes Security Groups Ready ✅✅" >&2
echo "----------------------------------------------" >&2
echo "Region            : $REGION" >&2
echo "VPC               : $VPC_ID" >&2
echo "Control Plane SG  : $CONTROL_PLANE_SG_ID" >&2
echo "Worker Node SG    : $WORKER_SG_ID" >&2
echo "----------------------------------------------" >&2
echo "To view details run:"
echo "aws ec2 describe-security-groups --group-ids $CONTROL_PLANE_SG_ID $WORKER_SG_ID --region $REGION --output table"

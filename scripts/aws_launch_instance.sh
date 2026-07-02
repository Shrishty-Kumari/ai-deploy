#!/usr/bin/env bash
# Launches a free-tier-eligible EC2 instance with a security group that
# allows SSH/HTTP/HTTPS, ready for this project.
# Requires: AWS CLI v2 configured (`aws configure`) with an IAM user/role
# that has EC2 permissions.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-ai-deploy-stack-key}"
SG_NAME="${SG_NAME:-ai-deploy-stack-sg}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
MY_IP="$(curl -s ifconfig.me)/32"

echo "==> Using region: $REGION"

echo "==> Finding latest Ubuntu 24.04 LTS AMI"
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --region "$REGION" --output text)
echo "    AMI: $AMI_ID"

echo "==> Creating key pair (saved to ./${KEY_NAME}.pem)"
aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$REGION" \
  --query "KeyMaterial" --output text > "${KEY_NAME}.pem"
chmod 400 "${KEY_NAME}.pem"

echo "==> Creating security group"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --region "$REGION" --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "ai-deploy-stack: SSH/HTTP/HTTPS" \
  --vpc-id "$VPC_ID" --region "$REGION" \
  --query "GroupId" --output text)

echo "    Security group: $SG_ID (restricting SSH to your current IP: $MY_IP)"
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
  --protocol tcp --port 22 --cidr "$MY_IP" > /dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 > /dev/null

echo "==> Launching $INSTANCE_TYPE instance"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --region "$REGION" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ai-deploy-stack}]" \
  --query "Instances[0].InstanceId" --output text)

echo "    Instance: $INSTANCE_ID (waiting for it to be running...)"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

echo "==> Allocating and associating an Elastic IP"
ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
  --query "AllocationId" --output text)
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" \
  --region "$REGION" > /dev/null

PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --region "$REGION" \
  --query "Addresses[0].PublicIp" --output text)

echo ""
echo "================================================================"
echo " Done. Instance is up at: $PUBLIC_IP"
echo ""
echo " Connect with:"
echo "   ssh -i ${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo ""
echo " Remember to set a AWS Budget alert so you don't get surprised"
echo " by charges: Billing console -> Budgets -> Create budget."
echo "================================================================"

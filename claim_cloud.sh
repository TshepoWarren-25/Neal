#!/bin/bash
# --- ONE-TIME BOOTSTRAP: CLAIM YOUR CLOUD ---
# This script creates the S3 state bucket and helps find the Load Balancer ARNs 
# so we can adopt them into the new S3 backend.

REGION="us-east-1"
BUCKET_NAME="nealstreet-tf-state-414061810385"

echo "⏳ Step 1: Creating persistent S3 State Bucket..."
aws s3 mb s3://$BUCKET_NAME --region $REGION || echo "Bucket already exists."

echo "🔍 Step 2: Locating orphaned Load Balancer ARNs..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names nealST-dev-alb-01 --query "LoadBalancers[0].LoadBalancerArn" --output text --region $REGION)
TG_ARN=$(aws elbv2 describe-target-groups --names nealST-dev-tg-01 --query "TargetGroups[0].TargetGroupArn" --output text --region $REGION)

if [ ! -z "$ALB_ARN" ]; then
  echo "--- NEW IMPORTS ---"
  echo "import {" >> terraform/imports.tf
  echo "  to = aws_lb.main" >> terraform/imports.tf
  echo "  id = \"$ALB_ARN\"" >> terraform/imports.tf
  echo "}" >> terraform/imports.tf
  echo "import {" >> terraform/imports.tf
  echo "  to = aws_lb_target_group.web" >> terraform/imports.tf
  echo "  id = \"$TG_ARN\"" >> terraform/imports.tf
  echo "}" >> terraform/imports.tf
  echo "✅ Added ALB and Target Group ARNs to imports.tf"
fi

echo "🚀 DONE! You are now ready to push and adopt these resources."
echo "URL will be available at: http://$(aws elbv2 describe-load-balancers --names nealST-dev-alb-01 --query "LoadBalancers[0].DNSName" --output text --region $REGION)"

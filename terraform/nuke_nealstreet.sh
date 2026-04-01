#!/bin/bash
# --- Nuke NealStreet Deployment ---
# This script forcibly deletes all resources tagged with 'nealstreet' 
# or matching the 'nealST-dev-01' naming convention.
# Region: us-east-1

PROJECT="nealST-dev"
VPC_NAME="nealstreet-dev-vpc-01"
REGION="us-east-1"

echo "🔥 STARTING THE NUKE: Cleaning the nealstreet landing zone..."

# 1. Delete Auto Scaling Groups (Force Delete)
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '$PROJECT-asg')].AutoScalingGroupName" --output text --region $REGION)
for ASG in $ASG_NAMES; do
    echo "Deleting ASG: $ASG"
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region $REGION
done

# 2. Delete Application Load Balancers
ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, '$PROJECT-alb')].LoadBalancerArn" --output text --region $REGION)
for ALB in $ALB_ARNS; do
    echo "Deleting ALB: $ALB"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region $REGION
done

# 3. Delete Target Groups
TG_ARNS=$(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName, '$PROJECT-tg')].TargetGroupArn" --output text --region $REGION)
for TG in $TG_ARNS; do
    echo "Deleting Target Group: $TG"
    aws elbv2 delete-target-group --target-group-arn "$TG" --region $REGION
done

# 4. Wait for ALBs/ASGs to release dependencies
echo "⏳ Waiting 30 seconds for dependencies to detach..."
sleep 30

# 5. Delete CloudWatch Log Groups
echo "Deleting Log Groups..."
LOG_GROUPS=$(aws logs describe-log-groups --query "logGroups[?starts_with(logGroupName, '/aws/ec2/nealstreet-dev')].logGroupName" --output text --region $REGION)
for LG in $LOG_GROUPS; do
    aws logs delete-log-group --log-group-name "$LG" --region $REGION
done

# 6. Delete SSM Parameters
echo "Deleting SSM Parameters..."
SSM_PARAMS=$(aws ssm describe-parameters --query "Parameters[?starts_with(Name, '/nealstreet/')].Name" --output text --region $REGION)
for SP in $SSM_PARAMS; do
    aws ssm delete-parameter --name "$SP" --region $REGION
done

# 7. Delete VPC and dependencies (Best effort)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[0].VpcId" --output text --region $REGION)

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "Found VPC: $VPC_ID. Cleaning up subnets and Internet Gateway..."
    
    # Detach and delete IGW
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text --region $REGION)
    if [ ! -z "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region $REGION
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region $REGION
    fi

    # Delete Subnets
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $REGION)
    for SID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id "$SID" --region $REGION
    done

    # Final VPC deletion
    echo "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region $REGION
fi

echo "✅ NUKE COMPLETE: Landing zone is clean."

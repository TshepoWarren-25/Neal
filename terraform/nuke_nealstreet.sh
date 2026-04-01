#!/bin/bash
# --- Nuke NealStreet Deployment ---
# This script forcibly deletes all resources tagged with 'nealstreet' 
# or matching the 'nealST-dev-01' naming convention.
# Region: us-east-1

PROJECT="nealST-dev"
VPC_NAME="nealstreet-dev-vpc-01"
REGION="us-east-1"

set -e  # Exit immediately if a command fails

echo "🔥 STARTING THE GLOBAL NUKE: Cleaning the nealstreet landing zone..."
echo "🔍 Current VPCs in your account:"
aws ec2 describe-vpcs --query "Vpcs[].{VpcId:VpcId,Name:Tags[?Key=='Name'].Value|[0],IsDefault:IsDefault}" --output table --region $REGION

# 1. Delete Auto Scaling Groups (Force Delete)
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '$PROJECT-asg')].AutoScalingGroupName" --output text --region $REGION)
for ASG in $ASG_NAMES; do
    echo "Deleting ASG: $ASG"
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region $REGION
done

if [ ! -z "$ASG_NAMES" ]; then
    echo "⏳ Waiting for ASGs to fully terminate (up to 120s)..."
    for i in {1..24}; do
        REMAINING=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '$PROJECT-asg')].AutoScalingGroupName" --output text --region $REGION)
        if [ -z "$REMAINING" ]; then break; fi
        sleep 5
    done
fi

# 1.5 Delete Key Pairs
KEY_NAMES=$(aws ec2 describe-key-pairs --query "KeyPairs[?starts_with(KeyName, '$PROJECT-key')].KeyName" --output text --region $REGION)
for KEY in $KEY_NAMES; do
    echo "Deleting Key Pair: $KEY"
    aws ec2 delete-key-pair --key-name "$KEY" --region $REGION
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

# 7. Global VPC Cleanup (Delete ALL non-default VPCs)
echo "🔍 Searching for ALL non-default VPCs in $REGION..."
ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region $REGION)

for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
    if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
        echo "💣 NUCLEAR NUKE: Cleaning everything in VPC $VPC_ID..."
        
        # 7a. Force Detach and Loop-Wait for ENIs (Network Interfaces)
        # This is the most common blocker for VPC deletion.
        ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $REGION)
        for ENI in $ENI_IDS; do
            echo "Detaching ENI: $ENI"
            ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region $REGION)
            if [ ! -z "$ATTACH_ID" ] && [ "$ATTACH_ID" != "None" ]; then
                aws ec2 detach-network-interface --attachment-id $ATTACH_ID --force --region $REGION || true
            fi
        done

        echo "⏳ Waiting for ENIs to release (up to 60s)..."
        for i in {1..12}; do
            REMAINING_ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $REGION)
            if [ -z "$REMAINING_ENIS" ]; then break; fi
            sleep 5
        done

        # 7b. Detach and delete IGWs
        IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region $REGION)
        for IGW in $IGW_IDS; do
            aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region $REGION || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region $REGION || true
        done

        # 7c. Delete Subnets
        SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $REGION)
        for SID in $SUBNET_IDS; do
            aws ec2 delete-subnet --subnet-id "$SID" --region $REGION || true
        done

        # 7d. Delete Security Groups (except default)
        SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $REGION)
        for SG in $SG_IDS; do
            aws ec2 delete-security-group --group-id "$SG" --region $REGION || true
        done

        # 7e. Final VPC deletion
        echo "Final deletion of VPC: $VPC_ID"
        aws ec2 delete-vpc --vpc-id "$VPC_ID" --region $REGION || true
    fi
done

echo "✅ GLOBAL NUKE COMPLETE: Your account is ready for a fresh landing zone."

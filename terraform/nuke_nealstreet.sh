#!/bin/bash
# --- DIAGNOSTIC NUCLEAR NUKE [HARD RESET MODE] ---
# Purpose: This script performs an absolute scrub of ALL compute and networking 
# resources in us-east-1 to ensure a clean landing zone.
# It is designed to be extremely aggressive to resolve resource leaks.

REGION="us-east-1"

# We DO NOT use set -e because we want the script to try cleaning 
# everything even if one specific deletion fails.

echo "🚨🚨🚨 STARTING ABSOLUTE ZERO CLEANUP [HARD RESET] 🚨🚨🚨"

# 1. KILL ALL AUTO SCALING
echo "Identifying EVERY Auto Scaling Group in $REGION..."
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text --region "$REGION")
for ASG in $ASG_NAMES; do
    echo "🚨 Deleting ASG: $ASG (Resetting capacity to 0 first)..."
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG" --min-size 0 --max-size 0 --desired-capacity 0 --region "$REGION" || true
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region "$REGION" || true
done

echo "Identifying EVERY Launch Template in $REGION..."
LT_IDS=$(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateId" --output text --region "$REGION")
for LT in $LT_IDS; do
    echo "Deleting Launch Template: $LT"
    aws ec2 delete-launch-template --launch-template-id "$LT" --region "$REGION" || true
done

# 2. KILL ALL INSTANCES (GLOBAL)
echo "Finding EVERY active EC2 instance in $REGION..."
ALL_INSTANCES=$(aws ec2 describe-instances --query "Reservations[].Instances[?State.Name!=\`terminated\`].InstanceId" --output text --region "$REGION")
if [ ! -z "$ALL_INSTANCES" ] && [ "$ALL_INSTANCES" != "None" ]; then
    echo "🚨 TERMINATING ALL INSTANCES: $ALL_INSTANCES"
    aws ec2 terminate-instances --instance-ids $ALL_INSTANCES --region "$REGION" || true
    echo "⏳ Waiting for instances to die..."
    aws ec2 wait instance-terminated --instance-ids $ALL_INSTANCES --region "$REGION" || true
    sleep 30
fi

# 3. KILL ALL LOAD BALANCING
echo "Finding EVERY Load Balancer in $REGION..."
ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text --region "$REGION")
for ALB in $ALB_ARNS; do
    echo "Deleting ALB: $ALB"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
done

# Wait for ALB to drop its listener locks
if [ ! -z "$ALB_ARNS" ] && [ "$ALB_ARNS" != "None" ]; then
    echo "⏳ Waiting 30s for ALB listener locks to drop..."
    sleep 30
fi

echo "Finding EVERY Target Group in $REGION..."
TG_ARNS=$(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text --region "$REGION")
for TG in $TG_ARNS; do
    echo "Deleting Target Group: $TG"
    aws elbv2 delete-target-group --target-group-arn "$TG" --region "$REGION" || true
done

# 4. RELEASE ALL ELASTIC IPs
echo "Finding and Releasing EVERY Elastic IP in $REGION..."
ALLOC_IDS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text --region "$REGION")
for ALLOC in $ALLOC_IDS; do
    if [ ! -z "$ALLOC" ] && [ "$ALLOC" != "None" ]; then
        echo "Releasing EIP: $ALLOC"
        aws ec2 disassociate-address --allocation-id "$ALLOC" --region "$REGION" || true
        aws ec2 release-address --allocation-id "$ALLOC" --region "$REGION" || true
    fi
done

# 5. SCRUB ALL VPCs (Non-Default)
echo "Finding all non-default VPCs..."
ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
    echo "💣 Nuking VPC: $VPC_ID"
    
    # Nested pass to clear sub-dependencies
    for pass in {1..5}; do
        echo "Pass $pass for $VPC_ID..."
        
        # Scrub ENIs
        ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION")
        for ENI in $ENI_IDS; do
            aws ec2 delete-network-interface --network-interface-id "$ENI" --region "$REGION" || true
        done

        # Scrub IGWs
        aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION" | while read igw; do
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" || true
        done

        # Scrub SGs (Empty them first)
        SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region "$REGION")
        for SG in $SG_IDS; do
            aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" --query "SecurityGroupRules[?IsEgress==\`false\`].SecurityGroupRuleId" --output text --region "$REGION" | xargs -r -n1 aws ec2 revoke-security-group-ingress --group-id "$SG" --region "$REGION" --security-group-rule-ids > /dev/null 2>&1 || true
            aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" --query "SecurityGroupRules[?IsEgress==\`true\`].SecurityGroupRuleId" --output text --region "$REGION" | xargs -r -n1 aws ec2 revoke-security-group-egress --group-id "$SG" --region "$REGION" --security-group-rule-ids > /dev/null 2>&1 || true
            aws ec2 delete-security-group --group-id "$SG" --region "$REGION" || true
        done

        # Scrub Subnets
        aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION" | xargs -r -n1 aws ec2 delete-subnet --region "$REGION" --subnet-id || true

        # Scrub RTs
        aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text --region "$REGION" | xargs -r -n1 aws ec2 delete-route-table --region "$REGION" --route-table-id || true

        sleep 5
    done

    echo "Final VPC deletion attempt: $VPC_ID"
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" || true
done

# 6. UNIVERSAL LOG & KEY WIPE
echo "Cleaning Log Groups and SSH Keys..."
aws logs describe-log-groups --query "logGroups[?contains(logGroupName, 'nealstreet')].logGroupName" --output text --region "$REGION" | xargs -r -n1 aws logs delete-log-group --log-group-name --region "$REGION" || true
aws ec2 describe-key-pairs --query "KeyPairs[?contains(KeyName, 'neal')].KeyName" --output text --region "$REGION" | xargs -r -n1 aws ec2 delete-key-pair --region "$REGION" --key-name || true

echo "✅ ABSOLUTE ZERO PURGE COMPLETE: Your landing zone is reset."

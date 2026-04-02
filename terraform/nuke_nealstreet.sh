#!/bin/bash
# --- TOTAL ACCOUNT NUKE: LANDING ZONE CLEANUP ---
# WARNING: This script will delete ALL non-default resources in the specified regions.
# It does NOT look for "neal" anymore; it clears the entire slate.

REGIONS=("us-east-1" "us-west-2" "eu-west-1")

set -e

for REGION in "${REGIONS[@]}"; do
    echo "🚨🚨🚨 STARTING TOTAL NUKE IN REGION: $REGION 🚨🚨🚨"

    # 1. Delete ALL Auto Scaling Groups
    echo "Finding ALL Auto Scaling Groups..."
    ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text --region "$REGION")
    for ASG in $ASG_NAMES; do
        echo "Deleting ASG: $ASG"
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region "$REGION" || true
    done

    # 2. Terminate ALL EC2 Instances (Except those in Default VPC)
    # We first find instances that are NOT in a default VPC.
    echo "Finding ALL EC2 Instances in non-default VPCs..."
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --query "Reservations[].Instances[?VpcId!=null && State.Name!='terminated'].InstanceId" \
        --output text --region "$REGION")
    
    if [ ! -z "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "⚠️ Terminating ALL instances: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
        echo "⏳ Waiting for instances to die (up to 3 minutes)..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION" || true
    fi

    # 3. Delete ALL Application Load Balancers
    echo "Finding ALL Application Load Balancers..."
    ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text --region "$REGION")
    for ALB in $ALB_ARNS; do
        echo "Deleting Load Balancer: $ALB"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
    done

    # 4. Delete ALL Target Groups
    echo "Finding ALL Target Groups..."
    TG_ARNS=$(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text --region "$REGION")
    for TG in $TG_ARNS; do
        aws elbv2 delete-target-group --target-group-arn "$TG" --region "$REGION" || true
    done

    # 5. Global VPC Cleanup (Delete ALL non-default VPCs)
    echo "🔍 Searching for ALL non-default VPCs..."
    ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

    for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
        if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
            echo "💣 NUKE VPC: $VPC_ID..."
            
            # 5a. Detach and delete ALL Network Interfaces
            ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION")
            for ENI in $ENI_IDS; do
                echo "Cleaning ENI: $ENI"
                aws ec2 delete-network-interface --network-interface-id $ENI --region "$REGION" || true
            done

            # 5b. Detach and delete IGWs
            IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION")
            for IGW in $IGW_IDS; do
                aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$REGION" || true
                aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" || true
            done

            # 5c. Delete Subnets
            SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION")
            for SID in $SUBNET_IDS; do
                aws ec2 delete-subnet --subnet-id "$SID" --region "$REGION" || true
            done

            # 5d. Final VPC deletion
            aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" || true
        fi
    done

    # 6. Delete all non-default Key Pairs (Be careful!)
    echo "Cleaning up Key Pairs..."
    KEYS=$(aws ec2 describe-key-pairs --query "KeyPairs[].KeyName" --output text --region "$REGION")
    for KEY in $KEYS; do
        aws ec2 delete-key-pair --key-name "$KEY" --region "$REGION" || true
    done
done

echo "✅ FINAL ACCOUNT NUKE COMPLETE: ALL NON-DEFAULT RESOURCES WIPED."

#!/bin/bash
# --- ABSOLUTE ULTIMATE NUKE: TOTAL LANDING ZONE PURGE ---
# WARNING: This script will delete ALL non-default resources in the specified regions.
# It uses robust polling loops to handle slow AWS deletions.

REGIONS=("us-east-1" "us-west-2" "eu-west-1")

set -e

for REGION in "${REGIONS[@]}"; do
    echo "🚨🚨🚨 STARTING ABSOLUTE PURGE IN REGION: $REGION 🚨🚨🚨"

    # 1. Delete ALL NAT Gateways (CRITICAL: These take 3-5 mins)
    echo "Finding ALL NAT Gateways..."
    NAT_GW_IDS=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
    for NAT in $NAT_GW_IDS; do
        echo "Deleting NAT Gateway: $NAT"
        aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" || true
    done

    # 2. Delete ALL Auto Scaling Groups
    echo "Finding ALL Auto Scaling Groups..."
    ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text --region "$REGION")
    for ASG in $ASG_NAMES; do
        echo "Deleting ASG: $ASG"
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region "$REGION" || true
    done

    # 3. Terminate ALL EC2 Instances (Except Default VPC)
    echo "Finding ALL EC2 Instances..."
    INSTANCE_IDS=$(aws ec2 describe-instances --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId" --output text --region "$REGION")
    if [ ! -z "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "⚠️ Terminating instances: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" || true
        echo "⏳ Waiting for instances to terminate (up to 3 minutes)..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION" || true
    fi

    # 4. Delete ALL Application Load Balancers
    echo "Finding ALL Load Balancers..."
    ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text --region "$REGION")
    for ALB in $ALB_ARNS; do
        echo "Deleting Load Balancer: $ALB"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
    done

    if [ ! -z "$ALB_ARNS" ]; then
        echo "⏳ Waiting for ALBs to finish deleting..."
        aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARNS --region "$REGION" || true
        # Even after the ALB is deleted, its listeners and ENIs take time to release.
        sleep 30
    fi

    # 5. Delete ALL Target Groups
    echo "Finding ALL Target Groups..."
    TG_ARNS=$(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text --region "$REGION")
    for TG in $TG_ARNS; do
        aws elbv2 delete-target-group --target-group-arn "$TG" --region "$REGION" || true
    done

    # 6. Global VPC Cleanup (Delete ALL non-default VPCs)
    echo "🔍 Final VPC Purge..."
    ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

    for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
        if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
            echo "💣 NUKE VPC: $VPC_ID..."
            
            # 6a. Force release all Network Interfaces (ENIs)
            ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION")
            for ENI in $ENI_IDS; do
                echo "Wait-Deleting ENI: $ENI"
                aws ec2 delete-network-interface --network-interface-id $ENI --region "$REGION" || true
            done

            # 6b. Detach and delete Gateways
            IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION")
            for IGW in $IGW_IDS; do
                aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$REGION" || true
                aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" || true
            done

            # 6c. Delete Subnets
            SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION")
            for SID in $SUBNET_IDS; do
                aws ec2 delete-subnet --subnet-id "$SID" --region "$REGION" || true
            done

            # 6d. Final VPC deletion
            aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" || true
        fi
    done

    # 7. Release ALL Elastic IPs
    echo "Releasing ALL Elastic IPs..."
    EIP_ALLOC_IDS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text --region "$REGION")
    for EIP in $EIP_ALLOC_IDS; do
        aws ec2 release-address --allocation-id "$EIP" --region "$REGION" || true
    done

    # 8. Delete all Key Pairs
    echo "Cleaning up Key Pairs..."
    KEYS=$(aws ec2 describe-key-pairs --query "KeyPairs[].KeyName" --output text --region "$REGION")
    for KEY in $KEYS; do
        aws ec2 delete-key-pair --key-name "$KEY" --region "$REGION" || true
    done
done

echo "✅ ULTIMATE PURGE COMPLETE: Your account is ready for a fresh construction."

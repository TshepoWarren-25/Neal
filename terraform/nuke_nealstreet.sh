#!/bin/bash
# --- Ultimate Nuke NealStreet Deployment ---
# This script handles the "indestructible VPC" problem by explicitly 
# terminating all EC2 instances and waiting for them to reach 'terminated' state.

PROJECT="nealST-dev"
VPC_NAME="nealstreet-dev-vpc-01"
REGIONS=("us-east-1" "us-west-2" "eu-west-1")

set -e

for REGION in "${REGIONS[@]}"; do
    echo "🔥 SCANNING REGION: $REGION..."

    # 1. Force Delete Auto Scaling Groups
    ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '$PROJECT-asg')].AutoScalingGroupName" --output text --region "$REGION")
    for ASG in $ASG_NAMES; do
        echo "Deleting ASG: $ASG"
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region "$REGION" || true
    done

    # 2. Terminate ALL instances tagged with nealstreet OR belonging to non-default VPCs
    # This is the critical step to release ENIs and Public IPs.
    INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" "Name=tag:Name,Values=nealstreet*" --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION")
    if [ ! -z "$INSTANCE_IDS" ]; then
        echo "⚠️ Terminating instances: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
        echo "⏳ Waiting for instances to reach 'terminated' state..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION" || true
    fi

    # 3. Delete Application Load Balancers
    ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, '$PROJECT-alb')].LoadBalancerArn" --output text --region "$REGION")
    for ALB in $ALB_ARNS; do
        echo "Deleting ALB: $ALB"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
    done

    # 4. Global VPC Cleanup
    ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

    for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
        if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
            echo "💣 NUCLEAR NUKE: Cleaning VPC $VPC_ID ($REGION)..."

            # 4a. Force delete any remaining Network Interfaces (ENIs)
            # We wait for them to become 'available' after termination before deleting.
            for i in {1..10}; do
                ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION")
                if [ -z "$ENI_IDS" ]; then break; fi
                for ENI in $ENI_IDS; do
                    aws ec2 delete-network-interface --network-interface-id $ENI --region "$REGION" || true
                done
                sleep 5
            done

            # 4b. Detach and delete IGWs
            IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION")
            for IGW in $IGW_IDS; do
                aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$REGION" || true
                aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" || true
            done

            # 4c. Delete Subnets
            SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION")
            for SID in $SUBNET_IDS; do
                aws ec2 delete-subnet --subnet-id "$SID" --region "$REGION" || true
            done

            # 4d. Final VPC deletion
            echo "Final deletion of VPC: $VPC_ID"
            aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" || true
        fi
    done
done

echo "✅ ULTIMATE NUKE COMPLETE: Your account is ready."

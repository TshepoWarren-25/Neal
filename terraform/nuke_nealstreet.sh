#!/bin/bash
# --- Global Nuke NealStreet Deployment ---
# This script forcibly deletes ALL non-default VPCs and their associated dependencies
# to ensure a clean landing zone for every deployment.

PROJECT="nealST-dev"
VPC_NAME="nealstreet-dev-vpc-01"
REGIONS=("us-east-1" "us-west-2" "eu-west-1")

set -e  # Exit immediately if any command fails. This is critical for seeing the error.

for REGION in "${REGIONS[@]}"; do
    echo "🔥 SCANNING REGION: $REGION..."
    
    # 0. List Current VPCs
    echo "🔍 Current non-default VPCs in $REGION:"
    aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].{VpcId:VpcId,Name:Tags[?Key=='Name'].Value|[0]}" --output table --region "$REGION"

    # 1. Delete Auto Scaling Groups (Force Delete)
    ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '$PROJECT-asg')].AutoScalingGroupName" --output text --region "$REGION")
    for ASG in $ASG_NAMES; do
        echo "Deleting ASG: $ASG"
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region "$REGION"
    done

    # 2. Delete Application Load Balancers
    ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, '$PROJECT-alb')].LoadBalancerArn" --output text --region "$REGION")
    for ALB in $ALB_ARNS; do
        echo "Deleting ALB: $ALB"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION"
    done

    # 3. Wait for termination
    echo "⏳ Waiting 60s for shut-down..."
    sleep 60

    # 4. Global VPC Cleanup
    ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

    for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
        if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ] && [ "$VPC_ID" != "null" ]; then
            echo "💣 NUCLEAR NUKE: Cleaning everything in VPC $VPC_ID ($REGION)..."
            
            # 4a. Delete NAT Gateways
            NAT_GW_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text --region "$REGION")
            for NAT in $NAT_GW_IDS; do
                echo "Deleting NAT Gateway: $NAT"
                aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION"
            done

            # 4b. Force Detach and Loop-Wait for ENIs (Network Interfaces)
            ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION")
            for ENI in $ENI_IDS; do
                echo "Detaching ENI: $ENI"
                ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region "$REGION")
                if [ ! -z "$ATTACH_ID" ] && [ "$ATTACH_ID" != "None" ]; then
                    aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region "$REGION" || true
                fi
            done

            # 4c. Detach and delete IGWs
            IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION")
            for IGW in $IGW_IDS; do
                aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$REGION" || true
                aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" || true
            done

            # 4d. Delete Subnets
            SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION")
            for SID in $SUBNET_IDS; do
                aws ec2 delete-subnet --subnet-id "$SID" --region "$REGION" || true
            done

            # 4e. Final VPC deletion
            # Note: We remove the '|| true' here. If this fails, we want to see the error!
            echo "Final deletion of VPC: $VPC_ID"
            aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
        fi
    done
done

echo "✅ GLOBAL NUKE COMPLETE: Your account is ready for a fresh landing zone."

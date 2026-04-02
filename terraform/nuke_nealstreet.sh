#!/bin/bash
# --- UNIVERSAL NUKE NEALSTREET DEPLOYMENT ---
# This script handles the "indestructible VPC" problem by releasing Elastic IPs,
# waiting for NAT Gateways to reach the 'deleted' state, and stopping error-masking
# so we can see the exact blocker if one remains.

REGION="us-east-1"
PROJECT_PREFIX="nealST-dev"
VPC_NAME="nealstreet-dev-vpc-01"

set -e

echo "🚨🚨🚨 STARTING UNIVERSAL ACCOUNT CLEANUP 🚨🚨🚨"

# 1. Terminate All Projects Specific Instances (Wait for them to be DEAD)
echo "Finding instances to terminate..."
INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" "Name=tag:Name,Values=nealstreet*" --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION")
if [ ! -z "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
    echo "⚠️ Terminating instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
fi

# 2. Delete ALL NAT Gateways and WAIT (They block VPC deletion for ~5 minutes)
echo "Cleaning NAT Gateways..."
NAT_GW_IDS=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
for NAT in $NAT_GW_IDS; do
    echo "Deleting NAT Gateway: $NAT"
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" || true
done

if [ ! -z "$NAT_GW_IDS" ]; then
    echo "⏳ Waiting for NAT Gateways to reach 'deleted' state (This takes up to 5 mins)..."
    for i in {1..30}; do
        STILL_DELETING=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
        if [ -z "$STILL_DELETING" ]; then break; fi
        sleep 10
    done
fi

# 3. Release ALL Elastic IPs (Mapped public addresses block IGW detachment)
echo "Releasing Elastic IPs..."
ALLOC_IDS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text --region "$REGION")
for ALLOC in $ALLOC_IDS; do
    echo "Releasing EIP: $ALLOC"
    aws ec2 release-address --allocation-id $ALLOC --region "$REGION" || true
done

# 4. Clean up Load Balancers
ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, '$PROJECT_PREFIX-alb')].LoadBalancerArn" --output text --region "$REGION")
for ALB in $ALB_ARNS; do
    echo "Deleting ALB: $ALB"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
done

# 5. Global VPC Cleanup (Delete ALL non-default VPCs)
ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")
for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
    echo "💣 NUCLEAR CLEANUP: VPC $VPC_ID"
    
    # 5a. Delete VPC Endpoints
    VPC_ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[].VpcEndpointId" --output text --region "$REGION")
    for VPCE in $VPC_ENDPOINT_IDS; do
        echo "Deleting VPC Endpoint: $VPCE"
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE" --region "$REGION" || true
    done

    # 5b. Delete VPC Peering Connections
    PEERING_IDS=$(aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region "$REGION")
    for PEER in $PEERING_IDS; do
        echo "Deleting VPC Peering: $PEER"
        aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$PEER" --region "$REGION" || true
    done

    # Detach and delete Gateways
    IGW_IDS=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION")
    for IGW in $IGW_IDS; do
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$REGION" || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" || true
    done

    # Delete Subnets
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION")
    for SID in $SUBNET_IDS; do
        aws ec2 delete-subnet --subnet-id "$SID" --region "$REGION" || true
    done

    # Delete the VPC itself (Show error if it fails!)
    echo "Final VPC deletion attempt: $VPC_ID"
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
done

# 6. Final Log Group Scrub
echo "Cleaning Log Groups..."
LOG_GROUPS=$(aws logs describe-log-groups --query "logGroups[?contains(logGroupName, 'nealstreet')].logGroupName" --output text --region $REGION)
for LG in $LOG_GROUPS; do
    aws logs delete-log-group --log-group-name "$LG" --region $REGION || true
done

echo "✅ CLEANUP COMPLETE: Account limit should be clear."

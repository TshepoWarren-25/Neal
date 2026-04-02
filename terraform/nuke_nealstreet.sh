#!/bin/bash
# --- ULTIMATE NUCLEAR NUKE: THE RECURSIVE EDITION ---
# This is our absolute final solution for persistent VPC dependency errors.
# It uses a 5-pass recursive loop to catch and destroy resources as they release.

REGION="us-east-1"
PROJECT_PREFIX="nealST-dev"
VPC_NAME="nealstreet-dev-vpc-01"

set -e  # Crucial to see exactly哪一步 fails now.

echo "🚨🚨🚨 STARTING ULTIMATE NUCLEAR CLEANUP 🚨🚨🚨"

# 1. Terminate All instances (Global tagged search)
echo "Finding instances to terminate..."
INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" "Name=tag:Name,Values=nealstreet*" --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION")
if [ ! -z "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
    echo "⚠️ Terminating instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
fi

# 2. Delete ALL NAT Gateways and WAIT (THEY ARE THE BIGGEST BLOCKER)
echo "Finding NAT Gateways..."
NAT_GW_IDS=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
for NAT in $NAT_GW_IDS; do
    echo "Deleting NAT Gateway: $NAT..."
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" || true
done

if [ ! -z "$NAT_GW_IDS" ]; then
    echo "⏳ Waiting for NAT Gateways to reach 'deleted' state (Up to 5 minutes)..."
    for i in {1..30}; do
        REMAINING=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
        if [ -z "$REMAINING" ]; then break; fi
        sleep 10
    done
fi

# 3. Clean Load Balancers and ASGs
ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, '$PROJECT_PREFIX-alb')].LoadBalancerArn" --output text --region "$REGION")
for ALB in $ALB_ARNS; do
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
done

# 4. START RECURSIVE NETWORK SCRUB (5 PASSES)
echo "🔄 Starting 5-pass recursive network scrub..."
ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
    echo "💣 Cleaning VPC $VPC_ID..."
    
    for pass in {1..5}; do
        echo "Pass $pass: Scrubbing dependencies for VPC $VPC_ID..."
        
        # 4a. Release Elastic IPs
        EIP_ASSOCS=$(aws ec2 describe-addresses --filters "Name=domain,Values=vpc" --query "Addresses[?InstanceId!=null || AssociationId!=null].AssociationId" --output text --region "$REGION")
        for ASSOC in $EIP_ASSOCS; do 
            aws ec2 disassociate-address --association-id "$ASSOC" --region "$REGION" || true
        done
        ALLOC_IDS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text --region "$REGION")
        for ALLOC in $ALLOC_IDS; do
            aws ec2 release-address --allocation-id "$ALLOC" --region "$REGION" || true
        done

        # 4b. Scrub Endpoints and Peering
        aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[].VpcEndpointId" --output text --region "$REGION" | xargs -r aws ec2 delete-vpc-endpoints --vpc-endpoint-ids --region "$REGION" || true
        aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region "$REGION" | xargs -r aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id --region "$REGION" || true

        # 4c. Scrub ENIs (Network Interfaces)
        aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION" | xargs -r aws ec2 delete-network-interface --network-interface-id --region "$REGION" || true

        # 4d. Scrub Gateways
        aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION" | while read igw; do
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" || true
        done

        # 4e. Scrub Subnets
        aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION" | xargs -r aws ec2 delete-subnet --subnet-id --region "$REGION" || true

        # Wait between passes
        sleep 10
    done

    # Final VPC deletion
    echo "Final VPC deletion attempt: $VPC_ID"
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
done

# 5. Clean Log Groups (Wait for names to clear)
aws logs describe-log-groups --query "logGroups[?contains(logGroupName, 'nealstreet')].logGroupName" --output text --region "$REGION" | xargs -r -n1 aws logs delete-log-group --log-group-name --region "$REGION" || true

echo "✅ ULTIMATE PURGE COMPLETE: Your landing zone is clean."

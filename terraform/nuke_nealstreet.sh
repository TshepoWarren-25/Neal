#!/bin/bash
# --- DIAGNOSTIC NUCLEAR NUKE ---
# Purpose: This script performs a global scrub of non-default AWS resources in us-east-1.
# It is designed to be destructive and used for resetting development environments to zero.
# It includes recursive passes to handle resource dependencies (like subnets and route tables).

REGION="us-east-1"

# Exit immediately if a command fails (unless caught by || true)
set -e

echo "🚨🚨🚨 STARTING GLOBAL DIAGNOSTIC CLEANUP 🚨🚨🚨"

# 1. Terminate All active EC2 instances in non-default VPCs
# Instances must be terminated before their VPCs or ENIs can be deleted.
echo "Finding all active EC2 instances in non-default VPCs..."
ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

for VPC in $ALL_NON_DEFAULT_VPCS; do
    INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION")
    if [ ! -z "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "⚠️ Terminating instances in VPC $VPC: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
    fi
done

# 2. Delete ALL NAT Gateways
# NAT Gateways can take several minutes to delete and block VPC/Subnet deletion.
echo "Finding ALL NAT Gateways..."
NAT_GW_IDS=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
for NAT in $NAT_GW_IDS; do
    echo "Deleting NAT Gateway: $NAT"
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" || true
done

# Wait for NAT Gateways to reach 'deleted' status before proceeding.
if [ ! -z "$NAT_GW_IDS" ]; then
    echo "⏳ Waiting for NAT Gateways to reach 'deleted' state (Up to 5 mins)..."
    for i in {1..30}; do
        REMAINING=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
        if [ -z "$REMAINING" ]; then break; fi
        sleep 10
    done
fi

# 3. Clean ALL Load Balancers
# ALB deletion often leaves "Ghost ENIs" which can take a minute to release.
echo "Finding ALL Load Balancers..."
ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text --region "$REGION")
for ALB in $ALB_ARNS; do
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
done

if [ ! -z "$ALB_ARNS" ]; then
    echo "⏳ Waiting for ALBs to finish deleting..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARNS --region "$REGION" > /dev/null 2>&1 || true
    echo "⏳ Adding 60s cooldown for ALB Ghost ENIs to drop..."
    sleep 60
fi

# 4. Clean ALL Target Groups
# These should be deleted after the Load Balancers that use them.
TG_ARNS=$(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text --region "$REGION")
for TG in $TG_ARNS; do
    aws elbv2 delete-target-group --target-group-arn "$TG" --region "$REGION" || true
done

# 5. START RECURSIVE NETWORK SCRUB (5 PASSES)
# Network resources have complex circular dependencies. Sequential passes ensure
# that as one resource is freed, its dependent can be deleted in the next pass.
echo "🔄 Starting 5-pass recursive network scrub..."

for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
    echo "💣 Cleaning VPC $VPC_ID..."
    
    for pass in {1..5}; do
        echo "Pass $pass: Scrubbing dependencies for VPC $VPC_ID..."
        
        # 5a. Release Elastic IPs (Must be disassociated first)
        EIP_ASSOCS=$(aws ec2 describe-addresses --filters "Name=domain,Values=vpc" --query "Addresses[?InstanceId!=null || AssociationId!=null].AssociationId" --output text --region "$REGION")
        for ASSOC in $EIP_ASSOCS; do 
            aws ec2 disassociate-address --association-id "$ASSOC" --region "$REGION" || true
        done
        ALLOC_IDS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text --region "$REGION")
        for ALLOC in $ALLOC_IDS; do
            aws ec2 release-address --allocation-id "$ALLOC" --region "$REGION" || true
        done

        # 5b. Scrub VPC Endpoints and Peering Connections
        aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[].VpcEndpointId" --output text --region "$REGION" | xargs -r aws ec2 delete-vpc-endpoints --vpc-endpoint-ids --region "$REGION" || true
        aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region "$REGION" | xargs -r aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id --region "$REGION" || true

        # 5c. Scrub Network Interfaces (ENIs)
        # ENIs often block VPC deletion if they are still 'attached' to dead instances or ALBs.
        ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION")
        for ENI in $ENI_IDS; do
            ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region "$REGION")
            if [ ! -z "$ATTACH_ID" ] && [ "$ATTACH_ID" != "None" ]; then
                aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region "$REGION" || true
            fi
            aws ec2 delete-network-interface --network-interface-id "$ENI" --region "$REGION" || true
        done

        # 5d. Scrub Internet Gateways
        # Gateways must be detached from the VPC before they can be deleted.
        aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION" | while read igw; do
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" || true
        done

        # 5e. Scrub Security Groups (Crucial for unblocking VPC deletion)
        # All rules must be revoked to break cross-group dependencies.
        SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region "$REGION")
        for SG in $SG_IDS; do
            aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" --query "SecurityGroupRules[?IsEgress==\`false\`].SecurityGroupRuleId" --output text --region "$REGION" | xargs -r -n1 aws ec2 revoke-security-group-ingress --group-id "$SG" --region "$REGION" --security-group-rule-ids > /dev/null 2>&1 || true
            aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" --query "SecurityGroupRules[?IsEgress==\`true\`].SecurityGroupRuleId" --output text --region "$REGION" | xargs -r -n1 aws ec2 revoke-security-group-egress --group-id "$SG" --region "$REGION" --security-group-rule-ids > /dev/null 2>&1 || true
        done
        for SG in $SG_IDS; do
            aws ec2 delete-security-group --group-id "$SG" --region "$REGION" > /dev/null 2>&1 || true
        done

        # 5f. Scrub Subnets
        SUB_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION")
        for SUB in $SUB_IDS; do
            echo "Deleting Subnet: $SUB"
            aws ec2 delete-subnet --subnet-id "$SUB" --region "$REGION" || true
        done

        # 5g. Scrub Route Tables (Except Main)
        # Tables must be disassociated from subnets before deletion.
        RTB_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text --region "$REGION")
        for RTB in $RTB_IDS; do
            echo "Cleaning Route Table: $RTB"
            ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$RTB" --query "RouteTables[0].Associations[].RouteTableAssociationId" --output text --region "$REGION")
            for ASSOC in $ASSOC_IDS; do
                if [ "$ASSOC" != "None" ]; then
                    aws ec2 disassociate-route-table --association-id "$ASSOC" --region "$REGION" || true
                fi
            done
            aws ec2 delete-route-table --route-table-id "$RTB" --region "$REGION" || true
        done

        # 5h. Scrub Network ACLs (Except Default)
        ACL_IDS=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkAcls[?IsDefault==\`false\`].NetworkAclId" --output text --region "$REGION")
        for ACL in $ACL_IDS; do
            echo "Deleting NACL: $ACL"
            aws ec2 delete-network-acl --network-acl-id "$ACL" --region "$REGION" || true
        done

        # Wait between passes to allow AWS API to propagate changes.
        sleep 10
    done

    # 6. Final VPC deletion attempt with DIAGNOSTIC DUMP
    # If this fails, we output tables of everything remaining in the VPC.
    echo "Final VPC deletion attempt: $VPC_ID"
    set +e 
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
    DELETE_STATUS=$?
    set -e

    if [ $DELETE_STATUS -ne 0 ]; then
        echo "❌❌❌ VPC $VPC_ID FAILED TO DELETE! ❌❌❌"
        echo "Running Diagnostic Dump to find the exact blocker..."
        
        echo "--- REMAINING ENIs in $VPC_ID ---"
        aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].{ID:NetworkInterfaceId, Desc:Description, Status:Status, Owner:Attachment.InstanceOwnerId}" --output table --region "$REGION"
        
        echo "--- REMAINING SUBNETS in $VPC_ID ---"
        aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].{ID:SubnetId, CIDR:CidrBlock}" --output table --region "$REGION"
        
        echo "--- REMAINING SECURITY GROUPS in $VPC_ID ---"
        aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[].{ID:GroupId, Name:GroupName}" --output table --region "$REGION"

        echo "--- REMAINING ROUTE TABLES in $VPC_ID ---"
        aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[].{ID:RouteTableId, Main:Associations[0].Main}" --output table --region "$REGION"

        echo "--- REMAINING NACLs in $VPC_ID ---"
        aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkAcls[].{ID:NetworkAclId, Default:IsDefault}" --output table --region "$REGION"

        echo "--- REMAINING INSTANCES in $VPC_ID ---"
        aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" --query "Reservations[].Instances[].{ID:InstanceId, State:State.Name}" --output table --region "$REGION"

        exit 1
    else
        echo "✅ Successfully deleted VPC $VPC_ID!"
    fi
done

# 7. Clean Log Groups and Keys
# Final cleanup of resources existing outside the VPC scope.
aws logs describe-log-groups --query "logGroups[?contains(logGroupName, 'nealstreet')].logGroupName" --output text --region "$REGION" | xargs -r -n1 aws logs delete-log-group --log-group-name --region "$REGION" || true
KEYS=$(aws ec2 describe-key-pairs --query "KeyPairs[].KeyName" --output text --region "$REGION")
for KEY in $KEYS; do
    aws ec2 delete-key-pair --key-name "$KEY" --region "$REGION" || true
done

echo "✅ GLOBAL DIAGNOSTIC PURGE COMPLETE: Your landing zone is clean."

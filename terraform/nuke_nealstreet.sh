#!/bin/bash
# --- DIAGNOSTIC NUCLEAR NUKE [TOTAL SCORCH MODE] ---
# Purpose: This script performs a global scrub of non-default AWS resources in us-east-1.
# It is designed to be destructive and used for resetting development environments to zero.
# It now includes ASG termination and account-wide EIP release to prevent out-pacing.

REGION="us-east-1"
set -e

# 1. UNIVERSAL INSTANCE TERMINATION (Tag-Based)
# We find anything with 'nealstreet' in the Name, regardless of VPC.
# This catches instances that might have leaked into the Default VPC.
echo "🔍 Searching for all instances tagged with 'nealstreet'..."
UNIVERSAL_IDS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=nealstreet*" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION")

if [ ! -z "$UNIVERSAL_IDS" ] && [ "$UNIVERSAL_IDS" != "None" ]; then
    echo "🚨 FOUND GHOST INSTANCES: $UNIVERSAL_IDS. Terminating now..."
    aws ec2 terminate-instances --instance-ids $UNIVERSAL_IDS --region "$REGION" > /dev/null
    aws ec2 wait instance-terminated --instance-ids $UNIVERSAL_IDS --region "$REGION"
    sleep 30
fi

# 2. Stop Auto-Scaling Recreation
# We delete ASGs and Launch Templates NEXT, so no new instances are launched while we work.
echo "Finding all Auto Scaling Groups..."
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text --region "$REGION")
for ASG in $ASG_NAMES; do
    echo "Deleting ASG: $ASG (Forcefully setting min/max to 0 first)..."
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG" --min-size 0 --max-size 0 --desired-capacity 0 --region "$REGION" || true
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete --region "$REGION" || true
done

echo "Finding all Launch Templates..."
LT_IDS=$(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateId" --output text --region "$REGION")
for LT in $LT_IDS; do
    echo "Deleting Launch Template: $LT"
    aws ec2 delete-launch-template --launch-template-id "$LT" --region "$REGION" || true
done

# 2. Terminate All active EC2 instances
echo "Finding all active EC2 instances in non-default VPCs..."
ALL_NON_DEFAULT_VPCS=$(aws ec2 describe-vpcs --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text --region "$REGION")

for VPC in $ALL_NON_DEFAULT_VPCS; do
    INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION")
    if [ ! -z "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "⚠️ Terminating instances in VPC $VPC: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
        echo "⏳ Waiting 30s for instance network hooks to release..."
        sleep 30
    fi
done

# 3. GLOBAL EIP WIPE (Account-wide us-east-1)
# This resolves the "mapped public address" error blocking Internet Gateways.
echo "Finding and Releasing ALL Elastic IPs..."
ALLOC_IDS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text --region "$REGION")
for ALLOC in $ALLOC_IDS; do
    if [ "$ALLOC" != "None" ] && [ ! -z "$ALLOC" ]; then
        echo "Releasing EIP: $ALLOC"
        aws ec2 disassociate-address --allocation-id "$ALLOC" --region "$REGION" || true
        aws ec2 release-address --allocation-id "$ALLOC" --region "$REGION" || true
    fi
done

# 4. Clean ALL NAT Gateways
echo "Finding ALL NAT Gateways..."
NAT_GW_IDS=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
for NAT in $NAT_GW_IDS; do
    echo "Deleting NAT Gateway: $NAT"
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" --region "$REGION" || true
done

if [ ! -z "$NAT_GW_IDS" ]; then
    echo "⏳ Waiting for NAT Gateways to reach 'deleted' state (Up to 5 mins)..."
    for i in {1..30}; do
        REMAINING=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available,deleting" --query "NatGateways[].NatGatewayId" --output text --region "$REGION")
        if [ -z "$REMAINING" ]; then break; fi
        sleep 10
    done
fi

# 4. Clean ALL Load Balancers (Universal Tag Search)
# This finds anything with 'nealST' name prefix, even if existing in Default VPC.
echo "Finding all Load Balancers with 'nealST' prefix..."
ALB_ARNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'nealST')].LoadBalancerArn" --output text --region "$REGION")
for ALB in $ALB_ARNS; do
    echo "Deleting Load Balancer: $ALB"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" --region "$REGION" || true
done

if [ ! -z "$ALB_ARNS" ] && [ "$ALB_ARNS" != "None" ]; then
    echo "⏳ Waiting for ALBs to finish deleting..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARNS --region "$REGION" > /dev/null 2>&1 || true
    echo "⏳ Adding 60s cooldown for ALB Ghost ENIs to drop..."
    sleep 60
fi

# 6. Clean ALL Target Groups
TG_ARNS=$(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text --region "$REGION")
for TG in $TG_ARNS; do
    aws elbv2 delete-target-group --target-group-arn "$TG" --region "$REGION" || true
done

# 7. START RECURSIVE NETWORK SCRUB (8 PASSES)
echo "🔄 Starting 8-pass deep network scrub..."

for VPC_ID in $ALL_NON_DEFAULT_VPCS; do
    echo "💣 Cleaning VPC $VPC_ID..."
    
    for pass in {1..8}; do
        echo "Pass $pass: Scrubbing dependencies for VPC $VPC_ID..."
        
        # 7a. Scrub ENIs (Network Interfaces)
        # We try to delete everything. If it's device-0, it'll eventually drop.
        ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION")
        for ENI in $ENI_IDS; do
            echo "Deleting ENI: $ENI"
            ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region "$REGION")
            if [ ! -z "$ATTACH_ID" ] && [ "$ATTACH_ID" != "None" ]; then
                aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region "$REGION" || true
            fi
            aws ec2 delete-network-interface --network-interface-id "$ENI" --region "$REGION" || true
        done

        # 7b. Scrub Gateways
        aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[].InternetGatewayId" --output text --region "$REGION" | while read igw; do
            echo "Detaching and Deleting Internet Gateway: $igw"
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" || true
        done

        # 7c. Scrub Security Groups
        SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region "$REGION")
        for SG in $SG_IDS; do
            # Flush rules before deletion to break circular dependencies
            aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" --query "SecurityGroupRules[?IsEgress==\`false\`].SecurityGroupRuleId" --output text --region "$REGION" | xargs -r -n1 aws ec2 revoke-security-group-ingress --group-id "$SG" --region "$REGION" --security-group-rule-ids > /dev/null 2>&1 || true
            aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" --query "SecurityGroupRules[?IsEgress==\`true\`].SecurityGroupRuleId" --output text --region "$REGION" | xargs -r -n1 aws ec2 revoke-security-group-egress --group-id "$SG" --region "$REGION" --security-group-rule-ids > /dev/null 2>&1 || true
            aws ec2 delete-security-group --group-id "$SG" --region "$REGION" > /dev/null 2>&1 || true
        done

        # 7d. Scrub Subnets
        SUB_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region "$REGION")
        for SUB in $SUB_IDS; do
            echo "Deleting Subnet: $SUB"
            aws ec2 delete-subnet --subnet-id "$SUB" --region "$REGION" || true
        done

        # 7e. Scrub Route Tables
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

        sleep 10
    done

    # 8. Final VPC deletion attempt
    echo "Final VPC deletion attempt: $VPC_ID"
    set +e 
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
    DELETE_STATUS=$?
    set -e

    if [ $DELETE_STATUS -ne 0 ]; then
        echo "❌❌❌ VPC $VPC_ID FAILED TO DELETE! ❌❌❌"
        # Diagnostics
        echo "--- REMAINING ENIs in $VPC_ID ---"
        aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].{ID:NetworkInterfaceId, Desc:Description, Status:Status, Owner:Attachment.InstanceOwnerId}" --output table --region "$REGION"
        exit 1
    else
        echo "✅ Successfully deleted VPC $VPC_ID!"
    fi
done

# 9. UNIVERSAL LOG GROUP & KEY CLEANUP
echo "Purging all Log Groups and Keys with 'nealstreet' in the Name..."
aws logs describe-log-groups --query "logGroups[?contains(logGroupName, 'nealstreet')].logGroupName" --output text --region "$REGION" | xargs -r -n1 aws logs delete-log-group --log-group-name --region "$REGION" || true

# 10. UNIVERSAL SECURITY GROUP CLEANUP (Tag-Based)
# Last resort for any groups that leaked into the Default VPC
echo "🔍 Searching for any orphaned Security Groups named 'nealST'..."
GHOST_SGS=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=nealST*" --query "SecurityGroups[].GroupId" --output text --region "$REGION")
for SG in $GHOST_SGS; do
    echo "Deleting Ghost Security Group: $SG"
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" || true
done

echo "✅ GLOBAL DIAGNOSTIC PURGE COMPLETE: Your landing zone is clean."

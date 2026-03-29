# Architecture Design: Rewards Web Tier

This document outlines the architectural design for the "rewards" service infrastructure on AWS, optimized for the dev environment and Free Tier eligibility.

## 1. System Architecture Diagram

```mermaid
graph TD
    User([Public User]) --> ALB[AWS Application Load Balancer]
    
    subgraph VPC ["AWS VPC (10.0.0.0/16)"]
        subgraph PublicSubnet ["Public Subnet (10.0.1.0/24)"]
            ALB
            subgraph ASG ["Auto Scaling Group"]
                EC2[EC2 Instance (t2.micro)]
            end
        end
        
        IGW[Internet Gateway]
    }
    
    EC2 --> CWL[CloudWatch Logs]
    EC2 --> SSM[SSM Parameter Store]
    ALB -- port 8080 --> EC2
    PublicSubnet --- IGW
```

## 2. Component Overview

### **Networking (VPC)**
- **Region**: `us-east-1` (default).
- **Topology**: Single-AZ deployment for dev.
- **Subnet Strategy**: A public subnet is used for both the ALB and EC2 instances to avoid NAT Gateway costs while maintaining outbound internet access for updates and log shipping.

### **Compute (EC2 & ASG)**
- **Instance Type**: `t2.micro` (Free Tier).
- **Fleet Management**: Auto Scaling Group (ASG) ensures a desired capacity of 1, with self-healing capabilities if an instance fails health checks.
- **OS**: Amazon Linux 2023.

### **Load Balancing (ALB)**
- **Type**: Application Load Balancer.
- **Protocol**: HTTP/80 (Inbound) -> HTTP/8080 (Application).
- **Health Checks**: Targeted at `/health` to ensure application-level readiness.

### **Configuration & Secrets**
- **Ansible**: Manages the OS state, security hardening, and application lifecycle.
- **Secrets**: `APP_SECRET` is stored in **AWS SSM Parameter Store** (SecureString) and injected into the service at runtime by Ansible.

### **Observability**
- **Logs**: **CloudWatch Unified Agent** is installed on EC2 instances to stream `/var/log/rewards.log` to a centralized CloudWatch Log Group.

## 3. Security Model

- **Security Group Isolation**:
  - **ALB SG**: Allows inbound 80 from `0.0.0.0/0`.
  - **Web SG**: Allows inbound 8080 **ONLY** from the ALB SG. 
  - **SSH**: Port 22 is allowed for Ansible management (restricted via CIDR in production).
- **IAM (Least Privilege)**: Instances use an IAM Role with specific policies for SSM Session Manager and CloudWatch logging, avoiding long-lived credentials.
- **IMDSv2**: Strictly enforced on all EC2 instances to prevent credential theft via SSRF.

## 4. Request Flow
1. User requests `http://<alb-dns>/health`.
2. ALB receives request on port 80.
3. ALB forwards request to an healthy EC2 instance on port 8080.
4. Python service responds with JSON status.
5. Response returns through the ALB to the User.

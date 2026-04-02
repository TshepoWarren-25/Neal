# 🚀 NealStreet: Automated Web-Tier Rewards Engine

Professional-grade infrastructure-as-code (IaC) and configuration management (CM) for a highly available, self-healing AWS web application. This project implements a **"Zero-Friction / Total Reset"** deployment strategy, ensuring every run starts from a clean, predictable state.

## 🏗️ Core Architecture Overview
This project provisions a full AWS stack in `us-east-1` (North Virginia) within the **Free Tier** limits.

*   **Networking**: Custom VPC with Multi-AZ Public Subnets, Internet Gateway, and optimized Route Tables.
*   **Compute**: Auto Scaling Group (ASG) maintaining a desired fleet of Amazon Linux 2023 instances.
*   **Load Balancing**: Application Load Balancer (ALB) with Layer 7 health checks on `/health`.
*   **Configuration**: Automated **Ansible** playbook for OS hardening, Python service deployment, and real-time secret discovery.
*   **Monitoring**: Centralized logging via **AWS CloudWatch** (Unified Agent) and **AWS SSM** for secure sessions.

## ⚡ Key Features
*   **"Total Scorch" Reset**: Integrated cleanup script (`nuke_nealstreet.sh`) that clears every previous resource (ASGs, Instances, LBs, EIPs) before a new build begins.
*   **State-Synchronized CI/CD**: Seamless GitHub Actions pipeline that clears the Terraform state before deployment to resolve dependency deadlocks.
*   **Secure Secret Management**: Application secrets are never stored in plain text; they are fetched at runtime by Ansible directly from **AWS SSM Parameter Store**.
*   **Hardened Infrastructure**: Strictly enforces **IMDSv2**, IAM Least Privilege, and security group encapsulation (ALB as the only perimeter entry).

## 🚀 Deployment Workflow
The entire deployment is fully automated through GitHub Actions.

1.  **Push to `main`**: Triggers the CI/CD pipeline.
2.  **Authentication**: Uses GitHub Environment Secrets (**Dev**) and encrypted SSH keys.
3.  **The Nuke**: Purges the us-east-1 region of any "Ghost" resources from previous runs.
4.  **Provisioning**: Terraform builds the VPC and Compute layers.
5.  **The Bridge**: Terraform automatically triggers Ansible via a `local-exec` provisioner.
6.  **Configuration**: Ansible deploys the Python app, configures `systemd`, and activates CloudWatch logging.

## 🛠️ Verification
Once the pipeline is green, the site is live at the **Site URL** printed in the GitHub log output. 
- **Endpoint**: `http://[ALB_DNS_NAME]/health`
- **Expected Response**: `{"service": "rewards", "status": "ok", ...}`

## 📁 Repository Structure
*   `terraform/`: HCL code for AWS infrastructure and the Nuke utility script.
*   `ansible/`: Configuration management playbooks and systemd templates.
*   `app/`: Minimal dependency-free Python health service.
*   `.github/workflows/`: CI/CD automation logic.

---
*Developed for the NealStreet Rewards Platform.*

# AWS IaC + Linux Configuration for Dev Web Tier

This project implements a secure, automated web tier for a rewards platform, optimized for AWS Free Tier and production-readiness.

## Prerequisites
- AWS CLI configured with appropriate credentials.
- Terraform >= 1.0.0
- Ansible >= 2.10
- SSH Private Key for EC2 access.

## Project Structure
- `/terraform`: Infrastructure as Code for VPC, ALB, ASG, and IAM.
- `/ansible`: OS and Application configuration management.
- `/app`: Minimal health check service in Python.
- `/.github/workflows`: CI/CD pipeline.

## Running Locally

### 1. Provision Infrastructure
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

### 2. Configure Instances
Note: Ansible requires the instances to be running and reachable.
```bash
cd ansible
# Update inventory.ini with EC2 public IP
ansible-playbook -i inventory.ini playbook.yml --user ec2-user --private-key /path/to/your/key.pem
```

### 3. Cleanup
To avoid costs (though most resources are free-tier eligible):
```bash
cd terraform
terraform destroy
```

## Environment Secret Demo
The value for `APP_SECRET` should be set in AWS SSM Parameter Store:
```bash
aws ssm put-parameter --name "/rewards/dev/APP_SECRET" --value "SuperSecretValue" --type "SecureString" --overwrite
```
The application will automatically fetch this during the Ansible run.

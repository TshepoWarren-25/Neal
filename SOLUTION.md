# Solution & Design Decisions

## 1. Architectural Choices

### Region and Availability
- **Single AZ**: Chosen to stay within Free Tier limits and reduce complexity for this dev-tier demonstration.
- **VPC Design**: A single public subnet is used for both the ALB and EC2 instances. 
  - *Rationale*: To avoid the hourly cost of a NAT Gateway (approx $32/mo), instances need a public IP for outbound access (OS updates, package installs).
  - *Security Posture*: Despite being in a public subnet, the EC2 instances are protected by Security Groups that only allow inbound traffic from the ALB's Security Group, satisfying the "not directly reachable" requirement.

### Security & Hardening
- **IMDSv2 Enforcement**: The EC2 Launch Template is configured to require IMDSv2 (Session Tokens). This mitigates certain SSRF (Server-Side Request Forgery) risks that could lead to credential theft in legacy IMDSv1.
- **Minimal IAM Scope**: The EC2 instances use an IAM Role with strictly required managed policies (`AmazonSSMManagedInstanceCore` and `CloudWatchAgentServerPolicy`) rather than broad administrative rights.
- **SG Isolation**: Even though the instance has a public IP (to avoid NAT Gateway costs), its Security Group allows **zero** inbound traffic from the internet on application ports—only the ALB is permitted.

## 2. Infrastructure as Code (Terraform)
- **Local State**: Used for this exercise for simplicity.
- **Trade-off**: In a production environment, we would use a remote backend (S3 + DynamoDB) to enable team collaboration and state locking.
- **Promotion to Prod**: To promote, we would use Terraform workspaces or directory-based separation (e.g., `environments/prod/`) with the same modules but different parameters (Multi-AZ, NAT Gateways, larger instances).

## 3. Configuration Management (Ansible)
- **Security Baseline**: Includes basic OS hardening (package updates, restrictive service user).
- **Service Lifecycle**: Managed via systemd to ensure the service persists across reboots.
- **Observability**: CloudWatch Unified Agent is configured to ship application logs (`/var/log/rewards.log`) to CloudWatch Logs. This provides a centralized and native audit trail.

## 4. Secret Management
- **Approach**: Secrets are never checked into Git. `APP_SECRET` is provisioned in AWS SSM Parameter Store.
- **Consumption**: The Ansible playbook fetches the secret at runtime and injects it into the systemd service unit as an environment variable.

## 5. Promotion Procedure to Prod
1. **GitHub Flow**: Merges to `main` trigger the `dev` deployment.
2. **Promotion**: 
   - Tag a release in Git (e.g., `v1.0.0`).
   - Trigger a separate workflow specifically for the `prod` environment.
   - The `prod` environment would use the same Terraform modules but with:
     - `instance_type = "t3.small"` (or larger).
     - `multi_az = true` (Provisioning subnets in at least 2 AZs).
     - `internal_alb = false` (Public ALB), but internal servers would move to truly private subnets behind a NAT Gateway for higher security isolation.

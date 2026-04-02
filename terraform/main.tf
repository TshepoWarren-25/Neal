# --- Provider Configuration ---
# Configures the AWS Provider with the region specified in variables.tf.
provider "aws" {
  region = var.aws_region
}

# --- VPC Configuration ---
# Provisioning a Virtual Private Cloud (VPC) to provide an isolated virtual network environment.
# We enable DNS hostnames and support to allow EC2 instances to resolve AWS service endpoints.
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "nealstreet-${var.environment}-vpc-01"
    environment = var.environment
    service     = "nealstreet"
    owner       = var.owner
    cost_center = "payments"
  }
}

# --- Internet Gateway ---
# Attaches an Internet Gateway to the VPC to allow communication between 
# resources in the VPC and the internet.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "nealstreet-${var.environment}-igw-01"
  }
}

# --- Public Subnets ---
# Subnet 01: Creates the first public subnet in the first specified Availability Zone.
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = var.availability_zones[0]

  tags = {
    Name        = "nealstreet-${var.environment}-subnet-01"
    environment = var.environment
  }
}

# Subnet 02: Creates the second public subnet in the second specified Availability Zone.
# This ensures regional high availability for the ALB.
resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = var.availability_zones[1]

  tags = {
    Name        = "nealstreet-${var.environment}-subnet-02"
    environment = var.environment
  }
}

# --- Public Route Table ---
# Defines the routing rules for the public subnets, 
# pointing all non-local traffic (0.0.0.0/0) to the Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "nealstreet-${var.environment}-public-rt-01"
  }
}

# --- Route Table Associations ---
# Explicitly links the public subnets to the public route table for internet access.
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# --- Security Groups ---

# ALB Security Group: Acts as the perimeter firewall.
# Only permits stateful HTTP (port 80) traffic from the public internet.
resource "aws_security_group" "alb" {
  name_prefix = "nealST-${var.environment}-alb-sg-01-"
  description = "Allow HTTP inbound to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Web Server Security Group: Protects the application tier.
# Only permits application traffic originating from the ALB Security Group (Perimeter).
resource "aws_security_group" "web" {
  name_prefix = "nealST-${var.environment}-web-sg-01-"
  description = "Allow traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  # Application Inbound: Port 8080 (defined in vars) restricted to ALB source.
  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # SSH Management Inbound: Port 22 allowed for Ansible configuration. 
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All Outbound: Permitted for log shipping and software updates.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Application Load Balancer (ALB) ---
# Distributes application traffic across multiple healthy targets.
resource "aws_lb" "main" {
  name               = "nealST-${var.environment}-alb-01"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = {
    Name = "nealstreet-${var.environment}-alb-01"
  }
}

# --- Target Group & Health Checks ---
# Defines the specific destination for forwarded traffic and monitors health status.
resource "aws_lb_target_group" "web" {
  name     = "nealST-${var.environment}-tg-01"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# --- ALB Listener ---
# Binds the ALB to port 80 and manages the default forwarding behavior.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# --- IAM Roles & Profiles ---

# EC2 Execution Role:
# Grants instances permissions to write to CloudWatch and read from SSM.
resource "aws_iam_role" "web_role" {
  name_prefix = "nealST-${var.environment}-web-role-01-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

# Inherited Policies for Management (SSM) and Logging (CloudWatch Agent).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.web_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# --- SSH Key & Access Management ---

# Local Private Key generation (RSA 4096).
resource "tls_private_key" "auto" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Local file storage for the generated key (used by Ansible).
resource "local_file" "auto_private_key" {
  count           = var.ssh_public_key == "" ? 1 : 0
  content         = tls_private_key.auto.private_key_pem
  filename        = abspath("${path.module}/${var.ssh_private_key_path}")
  file_permission = "0600"
}

# AWS Key Pair registration for EC2 instance injection.
resource "aws_key_pair" "deployer" {
  key_name   = "nealST-${var.environment}-key-01"
  public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.auto.public_key_openssh
}

# Wrapping the IAM Role for EC2 instance assignment.
resource "aws_iam_instance_profile" "web_profile" {
  name_prefix = "nealST-${var.environment}-web-profile-01-"
  role        = aws_iam_role.web_role.name
}

# --- Compute: Launch Template & ASG ---

# Blueprint for Scaling: Defines instance size, image, and network security.
resource "aws_launch_template" "web" {
  name_prefix   = "nealST-${var.environment}-web-lt-01-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.deployer.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.web_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              yum update -y
              EOF
  )

  tags = {
    Name = "nealstreet-${var.environment}-web-lt-01"
  }
}

# Lifecycle Management: Maintains the desired fleet of instances across AZs.
resource "aws_autoscaling_group" "web" {
  name_prefix         = "nealST-${var.environment}-asg-01-"
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1
  vpc_zone_identifier = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  target_group_arns   = [aws_lb_target_group.web.arn]

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "nealstreet-${var.environment}-web-01"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "environment"
    value               = var.environment
    propagate_at_launch = true
  }
}

# --- Logging & Monitoring ---

# Centralized Log Storage for the application.
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/ec2/nealstreet-${var.environment}-web-01"
  retention_in_days = 7
}

# --- SECRETS & ORCHESTRATION ---

# Application Secrets:
# Manages encrypted secret strings in AWS Systems Manager.
# 'ignore_changes' is used because these values are typically managed out-of-band.
resource "aws_ssm_parameter" "app_secret" {
  name        = "/nealstreet/${var.environment}/web/app_secret"
  description = "Demo application secret"
  type        = "SecureString"
  value       = "FIXME_OVERRIDE_OUTSIDE_REPO"
  overwrite   = true
  
  lifecycle {
    ignore_changes = all
  }
}

# --- Provisioning Gates ---

# Readiness Wait:
# Pauses the workflow for 120 seconds. This is a vital 'safety gate' to allow 
# the Auto Scaling Group (ASG) to fully boot the EC2 instance and assign its 
# public IP before Ansible attempts to connect.
resource "time_sleep" "wait_for_instance" {
  depends_on      = [aws_autoscaling_group.web]
  create_duration = "120s"
}

# Dynamic Instance Discovery:
# Queries the AWS API to find the Public IP of the running web instance.
data "aws_instances" "web" {
  instance_tags = {
    Name = "nealstreet-${var.environment}-web-01"
  }
  instance_state_names = ["running"]
  depends_on           = [time_sleep.wait_for_instance]
}

# Ansible Inventory Generation:
# Dynamically creates a standard INI inventory file. This translates 
# the AWS-native data into a format that Ansible understands.
resource "local_file" "ansible_inventory" {
  content  = "[webservers]\n${try(data.aws_instances.web.public_ips[0], "127.0.0.1")} ansible_user=ec2-user ansible_ssh_private_key_file=${var.ssh_private_key_path}"
  filename = "${path.module}/../ansible/inventory.ini"
}

# --- ANSIBLE PROVISIONER ---
# This is the bridge between Infrastructure and Configuration.
# It triggers the application deployment once the network and compute are ready.
resource "null_resource" "ansible_provisioner" {
  triggers = {
    instance_ip   = try(data.aws_instances.web.public_ips[0], "none")
    playbook_hash = filemd5("${path.module}/../ansible/playbook.yml")
  }

  provisioner "local-exec" {
    # Inline subshell to ensure we have the absolute latest Public IP.
    # We pass CloudWatch and SSM identities as external variables to the playbook.
    command = <<EOT
      PUBLIC_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=nealstreet-${var.environment}-web-01" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[0].PublicIpAddress" --output text --region ${var.aws_region})
      echo "[webservers]\n$PUBLIC_IP ansible_user=ec2-user ansible_ssh_private_key_file=${var.ssh_private_key_path}" > ${path.module}/../ansible/inventory.ini
      ansible-playbook -i ${path.module}/../ansible/inventory.ini -e 'log_group_name=${aws_cloudwatch_log_group.app_logs.name} ssm_parameter_name=${aws_ssm_parameter.app_secret.name}' ${path.module}/../ansible/playbook.yml
    EOT
  }

  depends_on = [local_file.ansible_inventory, aws_lb_listener.http, time_sleep.wait_for_instance]
}

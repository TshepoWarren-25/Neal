provider "aws" {
  region = var.aws_region
}

# --- VPC Configuration ---
# Provisioning a single-AZ VPC to stick to Free Tier limits.
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

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "nealstreet-${var.environment}-igw-01"
  }
}

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

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# --- Security Groups ---
# ALB Security Group: Perimeter security. Allows HTTP from any source.
resource "aws_security_group" "alb" {
  name_prefix = "nealST-${var.environment}-alb-sg-01-" # Using short prefix for ALB
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

# Web Server Security Group: Application tier security.
# Restricts traffic so that only the ALB can reach the web service.
resource "aws_security_group" "web" {
  name_prefix = "nealST-${var.environment}-web-sg-01-" # Using short prefix for Web
  description = "Allow traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  # Permit incoming requests on the application port, but ONLY from the ALB's SG.
  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # SSH access: Provisioned for Ansible. In a production setting, this CIDR
  # would be restricted to a management subnet or Bastion host.
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic for package updates and log shipping.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }


}

# --- ALB ---
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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }


}

# --- Compute Layer (ASG) ---
# IAM Role for EC2: Granting permissions for SSM and CloudWatch.
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

# Managed policies for SSM Session Manager and CloudWatch Agent.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"


}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.web_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"


}

# --- Access Management ---
# Automatically generate a temporary SSH key if the user hasn't provided one yet.
# This ensures that Ansible can always launch and configure the project.
resource "tls_private_key" "auto" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save the auto-generated private key to the path expected by Ansible.
resource "local_file" "auto_private_key" {
  count    = var.ssh_public_key == "" ? 1 : 0
  content  = tls_private_key.auto.private_key_pem
  filename = abspath("${path.module}/${var.ssh_private_key_path}")
  file_permission = "0600"
}

# Key Pair for SSH access: Uses either the provided key or the auto-generated one.
resource "aws_key_pair" "deployer" {
  key_name   = "nealST-${var.environment}-key-01"
  public_key = var.ssh_public_key != "" ? var.ssh_public_key : tls_private_key.auto.public_key_openssh
}

resource "aws_iam_instance_profile" "web_profile" {
  name_prefix = "nealST-${var.environment}-web-profile-01-"
  role = aws_iam_role.web_role.name
}

# Launch Template: Defines the blueprints for the EC2 instances.
resource "aws_launch_template" "web" {
  name_prefix   = "nealST-${var.environment}-web-lt-01-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.deployer.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.web_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true # Required for outbound internet without NAT Gateway
    security_groups             = [aws_security_group.web.id]
  }

  # Security Hardening: Enforce IMDSv2 strictly.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              # Update packages upon boot as a security baseline.
              yum update -y
              EOF
  )

  tags = {
    Name = "nealstreet-${var.environment}-web-lt-01"
  }
}

# Auto Scaling Group: Manages instance lifecycle and scaling.
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

# --- Observability ---
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/ec2/nealstreet-${var.environment}-web-01"
  retention_in_days = 7


}

# --- Secrets (Demo) ---
resource "aws_ssm_parameter" "app_secret" {
  name        = "/nealstreet/${var.environment}/web/app_secret"
  description = "Demo application secret"
  type        = "SecureString"
  value       = "FIXME_OVERRIDE_OUTSIDE_REPO" # Placeholder, user would set this manually or via CI
  overwrite   = true                         # Allow repeated runs to update the value
  
  lifecycle {
    ignore_changes = all
  }
}

# --- Wait for Instance Readiness ---
# Give the ASG enough time to start the instances and assign public IPs.
resource "time_sleep" "wait_for_instance" {
  depends_on = [aws_autoscaling_group.web]
  create_duration = "120s"
}

# --- Ansible Deployment Integration ---
# Dynamically fetch the public IP of the instance created by the ASG.
data "aws_instances" "web" {
  instance_tags = {
    Name = "nealstreet-${var.environment}-web-01"
  }
  instance_state_names = ["running"]
  
  # Ensure we wait for the ASG to actually launch the instance.
  depends_on = [time_sleep.wait_for_instance]
}

# Generate the Ansible inventory file.
resource "local_file" "ansible_inventory" {
  content  = "[webservers]\n${try(data.aws_instances.web.public_ips[0], "127.0.0.1")} ansible_user=ec2-user ansible_ssh_private_key_file=${var.ssh_private_key_path}"
  filename = "${path.module}/../ansible/inventory.ini"
}

# Trigger Ansible Playbook execution.
resource "null_resource" "ansible_provisioner" {
  triggers = {
    # Re-run if the instance IP changes or if the playbook content changes.
    instance_ip = try(data.aws_instances.web.public_ips[0], "none")
    playbook_hash = filemd5("${path.module}/../ansible/playbook.yml")
  }

  provisioner "local-exec" {
    # Dynamically find the Public IP at runtime just before Ansible starts.
    # This solves the race condition where the ASG hasn't assigned an IP yet during the Plan stage.
    command = <<EOT
      PUBLIC_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=nealstreet-${var.environment}-web-01" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[0].PublicIpAddress" --output text --region ${var.aws_region})
      echo "[webservers]\n$PUBLIC_IP ansible_user=ec2-user ansible_ssh_private_key_file=${var.ssh_private_key_path}" > ${path.module}/../ansible/inventory.ini
      ansible-playbook -i ${path.module}/../ansible/inventory.ini -e 'log_group_name=${aws_cloudwatch_log_group.app_logs.name} ssm_parameter_name=${aws_ssm_parameter.app_secret.name}' ${path.module}/../ansible/playbook.yml
    EOT
  }

  depends_on = [local_file.ansible_inventory, aws_lb_listener.http, time_sleep.wait_for_instance]
}

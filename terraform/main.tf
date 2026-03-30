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
    Name        = "nealstreet-vpc"
    environment = var.environment
    service     = "rewards"
    owner       = var.owner
    cost_center = "payments"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "nealstreet-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name        = "nealstreet-public-subnet"
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
    Name = "nealstreet-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security Groups ---
# ALB Security Group: Perimeter security. Allows HTTP from any source.
resource "aws_security_group" "alb" {
  name        = "nealstreet-alb-sg"
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
  name        = "nealstreet-web-sg"
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
  name               = "nealstreet-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id]

  tags = {
    Name = "nealstreet-alb"
  }
}

resource "aws_lb_target_group" "web" {
  name     = "nealstreet-tg"
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
# Fetching the latest Amazon Linux 2023 AMI via SSM Parameter Store.
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# IAM Role for EC2: Granting permissions for SSM and CloudWatch.
resource "aws_iam_role" "web_role" {
  name = "nealstreet-web-role"

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

# Key Pair for SSH access.
resource "aws_key_pair" "deployer" {
  key_name   = "nealstreet-deployer-key"
  public_key = var.ssh_public_key
}

resource "aws_iam_instance_profile" "web_profile" {
  name = "nealstreet-web-profile"
  role = aws_iam_role.web_role.name
}

# Launch Template: Defines the blueprints for the EC2 instances.
resource "aws_launch_template" "web" {
  name_prefix   = "nealstreet-web-"
  image_id      = data.aws_ssm_parameter.ami.value
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
    Name = "nealstreet-web-template"
  }
}

# Auto Scaling Group: Manages instance lifecycle and scaling.
resource "aws_autoscaling_group" "web" {
  name                = "nealstreet-asg"
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1
  vpc_zone_identifier = [aws_subnet.public.id]
  target_group_arns   = [aws_lb_target_group.web.arn]

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "rewards-web-server"
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
  name              = "/aws/ec2/rewards-web-server"
  retention_in_days = 7
}

# --- Secrets (Demo) ---
resource "aws_ssm_parameter" "app_secret" {
  name        = "/rewards/dev/APP_SECRET"
  description = "Demo application secret"
  type        = "SecureString"
  value       = "FIXME_OVERRIDE_OUTSIDE_REPO" # Placeholder, user would set this manually or via CI
  
  lifecycle {
    ignore_changes = [value]
  }
}

# --- Ansible Deployment Integration ---
# Dynamically fetch the public IP of the instance created by the ASG.
data "aws_instances" "web" {
  instance_tags = {
    Name = "rewards-web-server"
  }
  instance_state_names = ["running"]
  
  # Ensure we wait for the ASG to actually launch the instance.
  depends_on = [aws_autoscaling_group.web]
}

# Generate the Ansible inventory file.
resource "local_file" "ansible_inventory" {
  content  = "[webservers]\n${data.aws_instances.web.public_ips[0]} ansible_user=ec2-user ansible_ssh_private_key_file=${var.ssh_private_key_path}"
  filename = "${path.module}/../ansible/inventory.ini"
}

# Trigger Ansible Playbook execution.
resource "null_resource" "ansible_provisioner" {
  triggers = {
    # Re-run if the instance IP changes or if the playbook content changes.
    instance_ip = data.aws_instances.web.public_ips[0]
    playbook_hash = filemd5("${path.module}/../ansible/playbook.yml")
  }

  provisioner "local-exec" {
    # Check if the private key file is present and not empty. 
    # Use '|| echo' to ensure Terraform doesn't fail if Ansible is skipped.
    command = "[ -s ${var.ssh_private_key_path} ] && ansible-playbook -i ${local_file.ansible_inventory.filename} ${path.module}/../ansible/playbook.yml || echo 'Skipping Ansible: Key not found or empty.'"
  }

  depends_on = [local_file.ansible_inventory, aws_lb_listener.http]
}

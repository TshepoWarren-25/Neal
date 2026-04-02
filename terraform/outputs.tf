# --- Infrastructure Outputs ---
# These outputs provide the critical entry points and resource identification 
# needed after the provisioning process is complete.

output "alb_dns_name" {
  description = "The main entry point for the application. Browse to this URL to view the site."
  value       = aws_lb.main.dns_name
}

output "vpc_id" {
  description = "The unique identifier of the project VPC, used for networking and security auditing."
  value       = aws_vpc.main.id
}

output "public_subnets" {
  description = "A list of the public subnet IDs where the ALB and web instances reside."
  value       = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

output "web_instance_ips" {
  description = "The public IP addresses of the EC2 instances currently managed by the Auto Scaling Group."
  value       = data.aws_instances.web.public_ips
}

output "log_group_name" {
  description = "The CloudWatch Log Group where application and system logs are stored for inspection."
  value       = aws_cloudwatch_log_group.app_logs.name
}

output "ssm_parameter_name" {
  description = "The path to the SSM parameter used for managing application secrets securely."
  value       = aws_ssm_parameter.app_secret.name
}

output "aws_region" {
  description = "The primary AWS region where the infrastructure was deployed (e.g., us-east-1)."
  value       = var.aws_region
}

output "dashboard_link" {
  description = "A convenience URL to directly open the EC2 console filtered for NealStreet resources."
  value       = "https://${var.aws_region}.console.aws.amazon.com/ec2/v2/home?region=${var.aws_region}#Instances:search=nealstreet"
}

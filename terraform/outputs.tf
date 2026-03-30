output "alb_dns_name" {
  description = "The public DNS name of the Load Balancer. Use this URL to access your application."
  value       = aws_lb.main.dns_name
}

output "vpc_id" {
  description = "The ID of the VPC created for the project."
  value       = aws_vpc.main.id
}

output "public_subnets" {
  description = "The IDs of the public subnets."
  value       = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

output "web_instance_ips" {
  description = "The public IP addresses of the web servers (from ASG)."
  value       = data.aws_instances.web.public_ips
}

output "log_group_name" {
  description = "The name of the CloudWatch Log Group for application logs."
  value       = aws_cloudwatch_log_group.app_logs.name
}

output "ssm_parameter_name" {
  description = "The name of the SSM Parameter storing the application secret."
  value       = aws_ssm_parameter.app_secret.name
}

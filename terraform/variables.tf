variable "aws_region" {
  default = "us-east-1"
}

variable "environment" {
  default = "dev"
}

variable "owner" {
  default = "candidate"
}

variable "instance_type" {
  default = "t2.micro" # Free Tier eligible
}

variable "app_port" {
  default = 8080
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key for Ansible"
  type        = string
  default     = "../ansible/key.pem"
}

variable "ssh_public_key" {
  description = "The Public Key string to associate with the EC2 Key Pair (Required for SSH access)"
  type        = string
  sensitive   = true
  default     = "" 
}

variable "ami_id" {
  description = "Hardcoded AMI ID for us-east-1 to bypass DescribeImages restrictions"
  type        = string
  default     = "ami-0440d3b780d96b29d" # Amazon Linux 2023 (us-east-1)
}

variable "availability_zones" {
  description = "Hardcoded AZs for us-east-1 to bypass DescribeAvailabilityZones restrictions"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

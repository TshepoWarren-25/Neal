# --- Global Variable Definitions ---
# These variables define the core configuration for the NealStreet infrastructure.
# Default values are optimized for the AWS us-east-1 region and Free Tier eligibility.

variable "aws_region" {
  description = "The target AWS region for deployment (Primary: us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "The environment suffix for resource naming (e.g., dev, prod, staging)"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Tagging attribute to identify the resource owner"
  type        = string
  default     = "candidate"
}

variable "instance_type" {
  description = "EC2 Instance size. t2.micro is used to remain within the AWS Free Tier limits."
  type        = string
  default     = "t2.micro" 
}

variable "app_port" {
  description = "The target TCP port for the application service (Internal traffic)"
  type        = number
  default     = 8080
}

variable "ssh_private_key_path" {
  description = "The local workstation path where the SSH private key (.pem) will be stored for Ansible access."
  type        = string
  default     = "../ansible/key.pem"
}

variable "ssh_public_key" {
  description = "The RSA Public Key string. If provided, it will be used for the EC2 Key Pair. If empty, a key will be auto-generated."
  type        = string
  sensitive   = true
  default     = "" 
}

variable "ami_id" {
  description = "The Amazon Machine Image (AMI) ID for Amazon Linux 2023. Explicitly defined to ensure idempotent builds in us-east-1."
  type        = string
  default     = "ami-0440d3b780d96b29d" 
}

variable "availability_zones" {
  description = "List of Availability Zones (AZs) used for the VPC subnets to ensure high availability across the region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

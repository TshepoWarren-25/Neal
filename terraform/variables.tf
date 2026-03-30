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
  description = "The Public Key string to associate with the EC2 Key Pair"
  type        = string
  sensitive   = true
}

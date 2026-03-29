terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Note: For production, we would use a remote backend like S3.
  # For this exercise, local state is assumed as perSOLUTION.md discussion.
}

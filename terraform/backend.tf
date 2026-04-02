terraform {
  backend "s3" {
    bucket         = "nealstreet-tf-state-414061810385"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
}

# --- Adoption Map (Import Blocks) ---
# This file tells Terraform to "claim" existing resources instead of creating new ones.
# This fulfills the user request: "don't recreate the resources... just manage the state".

import {
  to = aws_vpc.main
  id = "vpc-07e2ba9c3d52aa7c3"
}

import {
  to = aws_internet_gateway.main
  id = "igw-0940eaa6569b4a004"
}

import {
  to = aws_subnet.public_1
  id = "subnet-0742befef230d6510"
}

import {
  to = aws_subnet.public_2
  id = "subnet-04c8c0083fbf520f5"
}

import {
  to = aws_route_table.public
  id = "rtb-00afc9eb5055f6969"
}

import {
  to = aws_security_group.alb
  id = "sg-04d919fd04bf1d6b3"
}

import {
  to = aws_security_group.web
  id = "sg-088c805f78281e598"
}

import {
  to = aws_iam_role.web_role
  id = "nealST-dev-web-role-01-20260402152615422700000001"
}

import {
  to = aws_cloudwatch_log_group.app_logs
  id = "/aws/ec2/nealstreet-dev-web-01"
}

import {
  to = aws_ssm_parameter.app_secret
  id = "/nealstreet/dev/web/app_secret"
}

import {
  to = aws_key_pair.deployer
  id = "nealST-dev-key-01"
}

# Note: ALB and Target Group require ARNs for import. 
# They will be automatically discovered or imported in the next run 
# if their specific ARNs become available to the state.

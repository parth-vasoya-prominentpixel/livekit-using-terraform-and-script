# Data sources for AWS account and region information
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}
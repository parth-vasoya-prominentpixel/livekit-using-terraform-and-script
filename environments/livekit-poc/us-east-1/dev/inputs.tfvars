region         = "us-east-1"
env            = "dev"
prefix_company = "lp"
company        = "livekit-poc"

# VPC Configuration
vpc_cidr        = "10.0.0.0/16"
private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS Configuration
cluster_name    = "livekit"
cluster_version = "1.34"

# Node Group Configuration
node_groups = {
  livekit_nodes = {
    instance_types = ["t3.medium"]
    min_size       = 1
    max_size       = 10
    desired_size   = 3
  }
}

# ElastiCache Redis Configuration
redis_node_type = "cache.t3.micro"

# Twilio CIDR blocks for SIP traffic (port 5060)
twilio_cidrs = [
  "54.172.60.0/23",
  "54.244.51.0/24",
  "54.171.127.192/26",
  "35.156.191.128/25",
  "54.65.63.192/26",
  "54.169.127.128/26",
  "54.252.254.64/26",
  "177.71.206.192/26"
]

# Deployment role ARN - Replace with your actual deployment role ARN
deployment_role_arn = "arn:aws:iam::918595516608:role/lp-iam-resource-creation-role"

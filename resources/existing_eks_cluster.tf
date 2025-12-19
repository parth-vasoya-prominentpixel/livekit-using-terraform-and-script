# Data sources for existing EKS cluster created by eksctl
locals {
  # Load cluster info from eksctl
  cluster_info = jsondecode(file("${path.module}/../terraform-cluster-info.json"))
}

# Data source for existing EKS cluster
data "aws_eks_cluster" "existing" {
  name = local.cluster_info.cluster_name
}

data "aws_eks_cluster_auth" "existing" {
  name = local.cluster_info.cluster_name
}

# Data source for existing VPC created by eksctl
data "aws_vpc" "existing" {
  id = local.cluster_info.vpc_id
}

# Get subnets from the existing VPC
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
  
  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
  
  filter {
    name   = "tag:kubernetes.io/role/elb"
    values = ["1"]
  }
}

# Security Group for SIP traffic (port 5060) - Twilio only
resource "aws_security_group" "sip_traffic" {
  name_prefix = "${local.cluster_info.cluster_name}-sip-"
  description = "Security group for SIP traffic from Twilio only"
  vpc_id      = data.aws_vpc.existing.id

  # Ingress rules for SIP traffic from Twilio CIDRs only
  dynamic "ingress" {
    for_each = var.twilio_cidrs
    content {
      description = "SIP UDP traffic from Twilio CIDR ${ingress.value}"
      from_port   = 5060
      to_port     = 5060
      protocol    = "udp"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = var.twilio_cidrs
    content {
      description = "SIP TCP traffic from Twilio CIDR ${ingress.value}"
      from_port   = 5060
      to_port     = 5060
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # Egress rule - allow all outbound
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.cluster_info.cluster_name}-sip-twilio"
  })
}

# Attach SIP security group to existing node groups
resource "aws_ec2_tag" "node_group_sip_sg" {
  for_each = toset(data.aws_subnets.private.ids)
  
  resource_id = each.value
  key         = "kubernetes.io/cluster/${local.cluster_info.cluster_name}"
  value       = "shared"
}

# Output existing cluster information
output "existing_cluster_info" {
  description = "Information about the existing EKS cluster"
  value = {
    cluster_name     = data.aws_eks_cluster.existing.name
    cluster_endpoint = data.aws_eks_cluster.existing.endpoint
    cluster_version  = data.aws_eks_cluster.existing.version
    vpc_id          = data.aws_vpc.existing.id
    private_subnets = data.aws_subnets.private.ids
    public_subnets  = data.aws_subnets.public.ids
  }
}

output "sip_security_group_id" {
  description = "Security group ID for SIP traffic"
  value       = aws_security_group.sip_traffic.id
}
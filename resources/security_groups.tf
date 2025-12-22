# Security Group for SIP traffic (port 5060) - Twilio only
resource "aws_security_group" "sip_traffic" {
  name_prefix = "${local.sg_name_prefix}-sip-"
  description = "Security group for SIP traffic from Twilio only"
  vpc_id      = module.vpc.vpc_id

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
    Name = "${local.eks_name}-sip-twilio"
  })
}

# Additional security group rule for EKS to access Redis
resource "aws_security_group_rule" "eks_to_redis" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = module.eks_al2023.cluster_security_group_id
  security_group_id        = module.redis.security_group_id
  description              = "Allow EKS cluster to access Redis"

  depends_on = [module.eks_al2023, module.redis]
}

# Additional security group rules for private subnets to access Redis
resource "aws_security_group_rule" "private_subnets_to_redis" {
  count             = length(module.vpc.private_subnets_cidr_blocks)
  type              = "ingress"
  from_port         = 6379
  to_port           = 6379
  protocol          = "tcp"
  cidr_blocks       = [module.vpc.private_subnets_cidr_blocks[count.index]]
  security_group_id = module.redis.security_group_id
  description       = "Allow private subnet ${count.index + 1} to access Redis"

  depends_on = [module.redis, module.vpc]
}
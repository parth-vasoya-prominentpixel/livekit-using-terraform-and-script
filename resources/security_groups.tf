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
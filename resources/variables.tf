###############################
# Common variables
###############################

variable "region" {
  description = "AWS region for resources"
  type        = string
}

variable "env" {
  description = "Environment name"
  type        = string
  validation {
    condition     = contains(["dev", "uat", "prod"], var.env)
    error_message = "env must be one of dev, uat, or prod."
  }
}

variable "prefix_company" {
  description = "Company prefix for resource naming"
  type        = string
}

variable "company" {
  description = "Company name"
  type        = string
}

###############################
# EKS Cluster variables
###############################

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.34"
}

###############################
# EKS Auto Mode variables
###############################

variable "auto_mode_enabled" {
  description = "Enable EKS Auto Mode for compute"
  type        = bool
  default     = true
}

###############################
# ElastiCache Redis variables
###############################

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.t3.micro"
}

###############################
# VPC variables
###############################

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

###############################
# Security variables
###############################

variable "twilio_cidrs" {
  description = "Twilio CIDR blocks for SIP traffic (port 5060)"
  type        = list(string)
  default = [
    "54.172.60.0/23",
    "54.244.51.0/24",
    "54.171.127.192/26",
    "35.156.191.128/25",
    "54.65.63.192/26",
    "54.169.127.128/26",
    "54.252.254.64/26",
    "177.71.206.192/26"
  ]
}

variable "deployment_role_arn" {
  description = "ARN of the deployment role that Terraform should assume"
  type        = string
  default     = ""
}

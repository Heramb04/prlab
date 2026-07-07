terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

variable "name" {
  description = "Name prefix for network resources"
  type        = string
  default     = "prlab"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across (EKS requires >= 2)"
  type        = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name, used to tag subnets for the AWS Load Balancer Controller and Karpenter auto-discovery"
  type        = string
}

# terraform-aws-modules/vpc is the de facto standard module for this: it
# correctly wires route tables, IGW, and NAT associations, which are easy
# to get subtly wrong (and expensive to debug) by hand.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  # /24s per AZ: plenty of IPs for a lab-sized node count, keeps the plan short.
  public_subnets  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]

  # Single NAT gateway shared across all private subnets, not one per AZ.
  # A NAT gateway is ~$32/month plus data processing charges just sitting
  # idle; on a $140 total credit budget, one shared NAT is the right
  # tradeoff for a lab even though it removes AZ-level fault isolation for
  # egress traffic. See docs/architecture.md.
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    # Karpenter discovers subnets via this tag instead of hardcoded IDs.
    "karpenter.sh/discovery" = var.cluster_name
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "nat_gateway_ids" {
  value = module.vpc.natgw_ids
}

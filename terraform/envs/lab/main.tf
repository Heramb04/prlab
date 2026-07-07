provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "prlab"
      ManagedBy = "terraform"
      Env       = "lab"
    }
  }
}

variable "region" {
  description = "AWS region for the lab environment"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name (created in Phase 1; referenced here for subnet tagging)"
  type        = string
  default     = "prlab-lab"
}

variable "budget_alert_email" {
  description = "Email address for AWS Budget threshold alerts"
  type        = string
}

variable "infra_repo" {
  description = "GitHub org/repo allowed to assume the Terraform-plan OIDC role"
  type        = string
  default     = "Heramb04/prlab"
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Bootstrap manages its own local state (see terraform/bootstrap); read its
# outputs here instead of hardcoding the bucket/table ARNs a second time.
data "terraform_remote_state" "bootstrap" {
  backend = "local"
  config = {
    path = "${path.module}/../../bootstrap/terraform.tfstate"
  }
}

locals {
  # EKS needs subnets in >= 2 AZs; keep it to exactly 2 to minimize the
  # number of NAT/route associations and keep the lab cheap and simple.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "budgets" {
  source = "../../modules/budgets"

  alert_email          = var.budget_alert_email
  monthly_limit_usd    = 50
  alert_thresholds_usd = [10, 25, 50]
}

module "network" {
  source = "../../modules/network"

  name         = "prlab"
  azs          = local.azs
  cluster_name = var.cluster_name
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name = "prlab-demo-app"
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  infra_repo       = var.infra_repo
  state_bucket_arn = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn
  lock_table_arn   = data.terraform_remote_state.bootstrap.outputs.lock_table_arn
}

# CI verification: trivial comment-only change to trigger the terraform.yml
# workflow and confirm it posts a clean plan comment (Phase 0 acceptance).

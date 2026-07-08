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

variable "demo_app_repo" {
  description = "GitHub org/repo allowed to assume the ECR-push OIDC role"
  type        = string
  default     = "Heramb04/prlab-demo-app"
}

variable "state_bucket_name" {
  description = "Name of the S3 state bucket created by terraform/bootstrap (must match backend.tf)"
  type        = string
  default     = "prlab-tfstate-211374268683"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  # Bootstrap manages its own local (gitignored, not CI-visible) state, so
  # CI can't read its outputs via terraform_remote_state. These ARNs are
  # deterministic from the bucket name + account ID instead, keeping this
  # config fully self-contained and CI-reproducible.
  state_bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"
  lock_table_arn   = "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.state_bucket_name}-lock"
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

  infra_repo          = var.infra_repo
  state_bucket_arn    = local.state_bucket_arn
  lock_table_arn      = local.lock_table_arn
  ecr_push_repos      = [var.demo_app_repo, var.infra_repo]
  ecr_repository_arns = [module.ecr.repository_arn, module.ecr.reaper_repository_arn]
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  region             = var.region
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids
}

variable "github_token" {
  description = "GitHub PAT for the ArgoCD PR generator + Notifications (never committed - passed via TF_VAR_github_token at apply time)"
  type        = string
  sensitive   = true
}

module "argocd" {
  source = "../../modules/argocd"

  cluster_name           = module.eks.cluster_name
  cluster_endpoint       = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_certificate_authority_data
  region                 = var.region
  github_token           = var.github_token
}

module "kyverno" {
  source = "../../modules/kyverno"

  cluster_name           = module.eks.cluster_name
  cluster_endpoint       = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_certificate_authority_data
  region                 = var.region
}

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name           = module.eks.cluster_name
  cluster_endpoint       = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_certificate_authority_data
  region                 = var.region
  oidc_provider_arn      = module.eks.oidc_provider_arn
}

module "spot_exporter" {
  source = "../../modules/spot-exporter"

  cluster_name      = var.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
}

# NOT instantiated: this Free Plan burner account has no FIS subscription
# (CreateExperimentTemplate fails with SubscriptionRequiredException -
# verified live). modules/fis is kept as the correct implementation for a
# normal account; on THIS account, spot-interruption handling is tested by
# injecting a synthetic EC2 "Spot Instance Interruption Warning" event
# into Karpenter's SQS interruption queue instead, which drives the exact
# same controller code path FIS would. See docs/architecture.md.
#
# module "fis" {
#   source       = "../../modules/fis"
#   cluster_name = var.cluster_name
# }

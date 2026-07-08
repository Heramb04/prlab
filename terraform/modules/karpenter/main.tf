terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
  }
}

variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_ca_certificate" {
  type = string
}

variable "region" {
  type = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster's IRSA OIDC provider ARN (from the eks module)"
  type        = string
}

provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

# The eks module's karpenter submodule wires the fiddly parts: controller
# IRSA role, node IAM role + access entry, and the SQS queue + EventBridge
# rules that deliver spot interruption / rebalance / instance-health events
# to Karpenter. Same buy-vs-build reasoning as the vpc/eks modules.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.37"

  cluster_name = var.cluster_name

  enable_irsa            = true
  irsa_oidc_provider_arn = var.oidc_provider_arn
  # Chart installs into kube-system (Karpenter's own recommendation since
  # v1); the submodule's IRSA trust defaults to karpenter:karpenter and
  # silently mismatches otherwise (controller crashloops on AssumeRole 403).
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  # Bare node role: Karpenter nodes get the same three managed policies a
  # managed node group would (worker, CNI, ECR read) via this module.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  tags = {
    Project = "prlab"
  }
}

# The eks module's controller policy predates Karpenter 1.12's
# instance-profile garbage-collection controller, which lists profiles
# under its /karpenter/ path prefix. Without this the controller logs a
# 403 every reconcile (harmless to provisioning, but noisy and it defeats
# profile cleanup).
data "aws_iam_policy_document" "controller_extra" {
  statement {
    effect    = "Allow"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "controller_extra" {
  name   = "karpenter-1-12-instance-profile-gc"
  role   = module.karpenter.iam_role_name
  policy = data.aws_iam_policy_document.controller_extra.json
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.12.1" # one minor behind latest (1.13.0), per project convention
  namespace  = "kube-system"

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }
  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.iam_role_arn
  }
  # Lab sizing: one replica (default is 2 for HA), modest resources.
  set {
    name  = "replicas"
    value = "1"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "512Mi"
  }
}

output "node_iam_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "queue_name" {
  value = module.karpenter.queue_name
}

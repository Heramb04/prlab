terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

variable "state_bucket_arn" {
  description = "ARN of the S3 bucket holding Terraform remote state (plan needs read access)"
  type        = string
}

variable "lock_table_arn" {
  description = "ARN of the DynamoDB state-lock table (plan needs lock/unlock access)"
  type        = string
}

variable "infra_repo" {
  description = "GitHub org/repo allowed to assume the Terraform-plan role, e.g. Heramb04/prlab"
  type        = string
}

variable "demo_app_repo" {
  description = "GitHub org/repo allowed to assume the ECR-push role, e.g. Heramb04/prlab-demo-app"
  type        = string
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the demo app's CI pushes images to"
  type        = string
}

# GitHub rotates the leaf cert regularly; fetching the current thumbprint
# via a live TLS handshake (rather than hardcoding one) is the documented
# approach so this doesn't silently break on GitHub's next rotation.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# Plan-only role: CI never applies. Trust is scoped to the specific repo so
# no other GitHub repo (even another one you own) can assume it.
data "aws_iam_policy_document" "terraform_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.infra_repo}:*"]
    }
  }
}

resource "aws_iam_role" "terraform_plan" {
  name                 = "prlab-github-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.terraform_plan_trust.json
  max_session_duration = 3600
}

# Broad but read-only: `terraform plan` needs to read the current state of
# every service the modules touch (EC2/VPC, EKS, ECR, IAM, budgets, ...).
# Hand-enumerating that list is brittle as modules grow, so this uses the
# AWS-managed ReadOnlyAccess policy rather than a bespoke one.
resource "aws_iam_role_policy_attachment" "terraform_plan_readonly" {
  role       = aws_iam_role.terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess doesn't cover writes, but plan still needs to read the
# state object and take/release the DynamoDB lock around that read.
data "aws_iam_policy_document" "terraform_state_access" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.state_bucket_arn}/envs/lab/terraform.tfstate"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [var.lock_table_arn]
  }
}

resource "aws_iam_role_policy" "terraform_state_access" {
  name   = "state-access"
  role   = aws_iam_role.terraform_plan.id
  policy = data.aws_iam_policy_document.terraform_state_access.json
}

output "terraform_plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}

# CI in the app repo only ever builds and pushes images (never touches the
# cluster - that's ArgoCD's job), so this role is scoped to ECR push actions
# on exactly one repository, nothing else.
data "aws_iam_policy_document" "ecr_push_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.demo_app_repo}:*"]
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  name                 = "prlab-github-ecr-push"
  assume_role_policy   = data.aws_iam_policy_document.ecr_push_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken (the docker-login step) is only ever granted on
  # resource "*" - ECR has no resource-level permission for it.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

output "ecr_push_role_arn" {
  value = aws_iam_role.ecr_push.arn
}

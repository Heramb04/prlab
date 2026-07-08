terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

variable "cluster_name" {
  type = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster's IRSA OIDC provider ARN"
  type        = string
}

# Read-only EC2 describes; the exporter computes spot-vs-on-demand savings
# from instance metadata + spot price history, nothing more.
module "exporter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name = "${var.cluster_name}-spot-exporter"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["monitoring:spot-exporter"]
    }
  }
}

data "aws_iam_policy_document" "exporter" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSpotPriceHistory",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "exporter" {
  name   = "ec2-read"
  role   = module.exporter_irsa.iam_role_name
  policy = data.aws_iam_policy_document.exporter.json
}

output "iam_role_arn" {
  value = module.exporter_irsa.iam_role_arn
}

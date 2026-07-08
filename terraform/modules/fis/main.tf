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

# FIS needs its own role; aws:ec2:send-spot-instance-interruptions requires
# ec2:SendSpotInstanceInterruptions plus describe to resolve targets.
data "aws_iam_policy_document" "fis_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name               = "${var.cluster_name}-fis-spot-interruption"
  assume_role_policy = data.aws_iam_policy_document.fis_trust.json
}

data "aws_iam_policy_document" "fis" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:SendSpotInstanceInterruptions",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis" {
  name   = "spot-interruption"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis.json
}

# Interrupts ONE random spot instance provisioned by the preview NodePool.
# durationBeforeInterruption=PT2M: the instance receives the standard
# 2-minute spot interruption notice first - exactly what a real
# reclamation looks like - so Karpenter's SQS-fed interruption handling
# has its normal warning window to cordon/drain and replace the node.
resource "aws_fis_experiment_template" "spot_interruption" {
  description = "Interrupt one preview spot node; previews must recover automatically"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt-preview-spot"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "preview-spot-nodes"
    }
  }

  target {
    name           = "preview-spot-nodes"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "karpenter.sh/nodepool"
      value = "preview"
    }
  }

  tags = {
    Name    = "${var.cluster_name}-preview-spot-interruption"
    Project = "prlab"
  }
}

output "experiment_template_id" {
  value = aws_fis_experiment_template.spot_interruption.id
}

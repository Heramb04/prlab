terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # Bootstrap has no remote backend by design: it creates the bucket/table
  # that every other config's backend depends on. State for this config
  # stays local (gitignored, not committed) and is applied once; if it's
  # ever lost, `terraform import` the bucket/table back rather than
  # recreating them.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "prlab"
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}

variable "region" {
  description = "AWS region for the prlab lab environment"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform remote state"
  type        = string
}

resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name

  # Prevents `terraform destroy` from silently deleting all Terraform state
  # history for the whole project; the bucket must be emptied and this
  # lifecycle block removed deliberately before it can go away.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    # AWS-managed key (alias/aws/s3), not a customer-managed CMK: same
    # encryption-at-rest guarantee checkov asks for, zero monthly key cost.
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.state_bucket_name}-lock"
  billing_mode = "PAY_PER_REQUEST" # no idle cost when the table isn't used
  hash_key     = "LockID"

  # Table holds nothing but lock rows in transit; PITR cost is negligible
  # at this size and it's cheap insurance against an accidental delete.
  point_in_time_recovery {
    enabled = true
  }

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.bucket
}

output "state_bucket_arn" {
  value = aws_s3_bucket.tf_state.arn
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_lock.name
}

output "lock_table_arn" {
  value = aws_dynamodb_table.tf_lock.arn
}

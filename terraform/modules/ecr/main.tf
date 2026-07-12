terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

variable "repository_name" {
  description = "Name of the ECR repository for the demo app images"
  type        = string
  default     = "prlab-demo-app"
}

resource "aws_ecr_repository" "app" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  # Lab images are disposable; never let leftover images block terraform destroy.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  # AWS-managed key (alias/aws/ecr), not a CMK: no monthly key fee.
  encryption_configuration {
    encryption_type = "KMS"
  }
}

# Untagged images (dangling manifests from re-pushes) expire fast; PR-tagged
# images live 14 days, comfortably longer than the reaper's 48h preview TTL
# so a preview's image never disappears out from under a running Application.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 3 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire pr-* tagged images after 14 days"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["pr-"]
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = 14
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Platform-owned images (the TTL reaper) live in their own repository so
# app-image and platform-image lifecycles stay independent.
resource "aws_ecr_repository" "reaper" {
  name                 = "prlab-reaper"
  image_tag_mutability = "IMMUTABLE"
  # Lab images are disposable; never let leftover images block terraform destroy.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "reaper" {
  repository = aws_ecr_repository.reaper.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 3 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 5 most recent tagged reaper images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Spot-savings Prometheus exporter image (exporters/spot_savings.py).
resource "aws_ecr_repository" "exporter" {
  name                 = "prlab-spot-exporter"
  image_tag_mutability = "IMMUTABLE"
  # Lab images are disposable; never let leftover images block terraform destroy.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "exporter" {
  repository = aws_ecr_repository.exporter.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 3 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 5 most recent tagged exporter images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "exporter_repository_url" {
  value = aws_ecr_repository.exporter.repository_url
}

output "exporter_repository_arn" {
  value = aws_ecr_repository.exporter.arn
}

output "repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.app.arn
}

output "repository_name" {
  value = aws_ecr_repository.app.name
}

output "reaper_repository_url" {
  value = aws_ecr_repository.reaper.repository_url
}

output "reaper_repository_arn" {
  value = aws_ecr_repository.reaper.arn
}

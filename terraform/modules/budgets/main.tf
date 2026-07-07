terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

variable "alert_email" {
  description = "Email address to receive budget threshold notifications"
  type        = string
}

variable "monthly_limit_usd" {
  description = "Monthly budget limit in USD used to compute alert thresholds"
  type        = number
  default     = 50
}

variable "alert_thresholds_usd" {
  description = "Absolute USD amounts (actual spend, not forecast) that each trigger a separate email alert"
  type        = list(number)
  default     = [10, 25, 50]
}

resource "aws_sns_topic" "budget_alerts" {
  name = "prlab-budget-alerts"
  # AWS-managed key, not a CMK: encrypts the topic at rest for free.
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "budget_alerts_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "prlab-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.alert_thresholds_usd
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

output "sns_topic_arn" {
  value = aws_sns_topic.budget_alerts.arn
}

output "budget_name" {
  value = aws_budgets_budget.monthly.name
}

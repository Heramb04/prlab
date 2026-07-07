terraform {
  required_version = ">= 1.7"

  backend "s3" {
    bucket         = "prlab-tfstate-211374268683"
    key            = "envs/lab/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "prlab-tfstate-211374268683-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

# ==============================================================================
# Main Terraform Configuration Entry Point
# Project: DevSecOps Home Test - AWS ECS Fargate & Secure VPC Infrastructure
# ==============================================================================

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Compliance  = "DevSecOps-Baseline"
  }
}

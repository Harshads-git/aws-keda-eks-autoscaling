# =============================================================================
# terraform/backend.tf — Terraform Remote State Configuration
# =============================================================================
# Stores terraform.tfstate in S3 instead of locally.
#
# SETUP REQUIRED before using this file:
#   1. Run: bash scripts/setup-terraform-state.sh
#   2. Replace YOUR_ACCOUNT_ID with your actual AWS account ID
#      (find it: aws sts get-caller-identity --query Account --output text)
#   3. Run: terraform init
#      (Terraform will ask to migrate local state to S3 — answer 'yes')
#
# Why separate backend.tf from main.tf:
#   Backend configuration cannot use variables (Terraform limitation).
#   Keeping it in its own file makes the constraint clear and
#   makes it easy to grep for the account ID that needs updating.
#
# The backend block in main.tf (currently commented) references this file's
# intent — this file IS the backend configuration.
# =============================================================================

terraform {
  backend "s3" {
    # ── Replace YOUR_ACCOUNT_ID with your AWS account ID ──────────────────
    # Example: "183264980"
    # Get yours: aws sts get-caller-identity --query Account --output text
    bucket = "keda-demo-tfstate-YOUR_ACCOUNT_ID"

    # Path within the bucket — namespaced to avoid conflicts if you reuse
    # this bucket for multiple projects (common practice)
    key = "aws-keda-eks-autoscaling/terraform.tfstate"

    # Must match the bucket's region (set in setup-terraform-state.sh)
    region = "us-east-1"

    # Encrypt state at rest (belt-and-suspenders with bucket encryption)
    encrypt = true

    # DynamoDB table for state locking (created by setup-terraform-state.sh)
    # Prevents two concurrent 'terraform apply' runs from corrupting state
    dynamodb_table = "keda-demo-tfstate-lock"
  }
}

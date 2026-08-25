# =============================================================================
# terraform/modules/irsa/consumer-role.tf
# IAM Role for the SQS Consumer Application Pods
# =============================================================================
# This role is annotated on the Kubernetes ServiceAccount in:
#   manifests/serviceaccount.yaml → eks.amazonaws.com/role-arn: <this role ARN>
#
# How this role gets used at runtime (the full IRSA flow):
#   1. Pod starts with serviceAccountName: keda-demo (see manifests/deployment.yaml)
#   2. EKS pod identity webhook detects the IRSA annotation on the SA
#   3. Webhook injects into the pod:
#        AWS_ROLE_ARN=arn:aws:iam::<account>:role/keda-demo-dev-app-role
#        AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/token
#   4. boto3 (in app.py) reads these env vars automatically via the
#        botocore.credentials.AssumeRoleWithWebIdentityFetcher
#   5. boto3 calls STS: AssumeRoleWithWebIdentity(JWT from token file)
#   6. STS validates: JWT signature + trust policy condition (step 7 below)
#   7. Trust policy condition checked:
#        oidc.eks.us-east-1.amazonaws.com/id/XXXX:sub
#        == "system:serviceaccount:keda-demo:keda-demo"
#        (namespace:serviceaccount format)
#   8. STS returns temporary credentials (1-hour lifetime, auto-refreshed)
#   9. boto3 uses credentials: sqs:ReceiveMessage, DeleteMessage, etc.
#
# GCP Workload Identity equivalent:
#   google_service_account + google_service_account_iam_binding
#   member: "serviceAccount:<project>.svc.id.goog[<namespace>/<sa-name>]"
# =============================================================================

locals {
  # Extract the OIDC provider ID from the issuer URL
  # URL format: https://oidc.eks.us-east-1.amazonaws.com/id/ABCDEF1234567890
  # ID  format:                                               ABCDEF1234567890
  oidc_provider_id = replace(var.cluster_oidc_issuer_url, "https://", "")
}

# ── Consumer App IAM Role ─────────────────────────────────────────────────────
resource "aws_iam_role" "consumer" {
  name        = "${var.project_name}-${var.environment}-app-role"
  description = "IRSA role for keda-demo consumer pods — SQS receive/delete access"

  # ── Trust Policy ────────────────────────────────────────────────────────────
  # Defines WHO can assume this role.
  # The Condition is the critical security boundary:
  #   Only the specific ServiceAccount 'keda-demo' in namespace 'keda-demo'
  #   can assume this role. NOT any other pod in the cluster.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSConsumerIRSA"
        Effect = "Allow"
        Principal = {
          # The OIDC provider is the trusted identity issuer
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # sub claim: identifies the specific Kubernetes ServiceAccount
            # Format: system:serviceaccount:<namespace>:<service-account-name>
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:${var.app_namespace}:${var.app_service_account}"

            # aud claim: the audience must be STS (security validation)
            "${local.oidc_provider_id}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "${var.project_name}-${var.environment}-app-role"
    Component = "consumer-pod"
    IRSAFor   = "${var.app_namespace}/${var.app_service_account}"
  }
}

# ── Attach SQS Consumer Policy ───────────────────────────────────────────────
# The actual permissions: what this role can DO once assumed.
# Policy was created in terraform/modules/sqs/main.tf (aws_iam_policy.consumer).
# Permissions: sqs:ReceiveMessage, DeleteMessage, ChangeMessageVisibility,
#              GetQueueAttributes, GetQueueUrl
resource "aws_iam_role_policy_attachment" "consumer_sqs" {
  role       = aws_iam_role.consumer.name
  policy_arn = var.consumer_policy_arn
}

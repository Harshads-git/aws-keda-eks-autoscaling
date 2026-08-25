# =============================================================================
# terraform/modules/irsa/keda-role.tf
# IAM Role for the KEDA Operator (metric polling from SQS)
# =============================================================================
# KEDA needs to read the SQS queue depth to compute desired replica counts.
# This role grants KEDA ONLY the minimum permissions to do that:
#   sqs:GetQueueAttributes  → reads ApproximateNumberOfMessages
#   sqs:GetQueueUrl         → resolves queue name to URL
#
# KEDA cannot: ReceiveMessage, DeleteMessage, or anything else.
# This is the principle of least privilege applied rigorously.
#
# Two-role architecture (why KEDA and consumer have separate roles):
#
#   keda-operator-role (this file)         keda-demo-app-role (consumer-role.tf)
#   ────────────────────────────────       ───────────────────────────────────────
#   Assumed by: KEDA operator pod          Assumed by: keda-demo consumer pods
#   SA: keda/keda-operator                 SA: keda-demo/keda-demo
#   Permissions: sqs:GetQueueAttributes    Permissions: sqs:ReceiveMessage,
#                sqs:GetQueueUrl                        sqs:DeleteMessage,
#                                                       sqs:ChangeMessageVisibility
#
#   If we used ONE role for both:
#     - KEDA pod would have message receive/delete permissions → over-privileged
#     - A KEDA vulnerability could lead to message data leakage
#     - Violates principle of least privilege
#
# TriggerAuthentication connection:
#   manifests/keda-trigger-auth.yaml → podIdentity.provider: aws
#   This tells KEDA to use its operator pod's IRSA role (this file)
#   for authenticating with AWS when reading the SQS metric.
# =============================================================================

# ── KEDA Operator IAM Role ────────────────────────────────────────────────────
resource "aws_iam_role" "keda_operator" {
  name        = "${var.project_name}-${var.environment}-keda-operator-role"
  description = "IRSA role for KEDA operator — read-only SQS metric access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSKEDAOperatorIRSA"
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # KEDA operator runs in the 'keda' namespace
            # ServiceAccount name: keda-operator (installed by Helm on Day 16)
            "${local.oidc_provider_id}:sub" = "system:serviceaccount:${var.keda_namespace}:${var.keda_service_account}"
            "${local.oidc_provider_id}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "${var.project_name}-${var.environment}-keda-operator-role"
    Component = "keda-operator"
    IRSAFor   = "${var.keda_namespace}/${var.keda_service_account}"
  }
}

# ── Attach KEDA SQS Read-Only Policy ─────────────────────────────────────────
# Policy was created in terraform/modules/sqs/main.tf (aws_iam_policy.keda_operator)
# Permissions: sqs:GetQueueAttributes, sqs:GetQueueUrl — NOTHING else
resource "aws_iam_role_policy_attachment" "keda_sqs" {
  role       = aws_iam_role.keda_operator.name
  policy_arn = var.keda_operator_policy_arn
}

# ── Update manifests/serviceaccount.yaml annotation ──────────────────────────
# After terraform apply, get the consumer role ARN:
#   terraform output -raw consumer_role_arn
#
# Then update manifests/serviceaccount.yaml:
#   eks.amazonaws.com/role-arn: <terraform output -raw consumer_role_arn>
#
# And update manifests/keda-trigger-auth.yaml (no change needed — uses podIdentity)
# KEDA Helm chart must be installed with the keda-operator-role ARN annotation:
#   helm install keda kedacore/keda \
#     --namespace keda \
#     --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<keda_operator_role_arn>

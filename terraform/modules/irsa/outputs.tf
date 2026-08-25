# =============================================================================
# terraform/modules/irsa/outputs.tf
# =============================================================================

output "consumer_role_arn" {
  description = <<-EOF
    ARN of the consumer pod IRSA role.
    USE THIS in manifests/serviceaccount.yaml:
      annotations:
        eks.amazonaws.com/role-arn: <this value>
    Get with: terraform output -raw consumer_role_arn
  EOF
  value = aws_iam_role.consumer.arn
}

output "consumer_role_name" {
  description = "Name of the consumer pod IAM role."
  value       = aws_iam_role.consumer.name
}

output "keda_operator_role_arn" {
  description = <<-EOF
    ARN of the KEDA operator IRSA role.
    USE THIS in the KEDA Helm install command (Day 16):
      --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<this value>
    Get with: terraform output -raw keda_operator_role_arn
  EOF
  value = aws_iam_role.keda_operator.arn
}

output "keda_operator_role_name" {
  description = "Name of the KEDA operator IAM role."
  value       = aws_iam_role.keda_operator.name
}

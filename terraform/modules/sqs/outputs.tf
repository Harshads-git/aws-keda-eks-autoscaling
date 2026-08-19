# =============================================================================
# terraform/modules/sqs/outputs.tf
# =============================================================================

output "queue_url" {
  description = "Main SQS queue URL. Set as SQS_QUEUE_URL in K8s ConfigMap."
  value       = aws_sqs_queue.main.url
}

output "queue_arn" {
  description = "Main SQS queue ARN. Used in IAM policy Resource blocks."
  value       = aws_sqs_queue.main.arn
}

output "queue_name" {
  description = "Main SQS queue name. Used in KEDA ScaledObject metadata."
  value       = aws_sqs_queue.main.name
}

output "dlq_url" {
  description = "Dead Letter Queue URL. Use to inspect failed messages."
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = "Dead Letter Queue ARN."
  value       = aws_sqs_queue.dlq.arn
}

output "consumer_policy_arn" {
  description = "IAM policy ARN for consumer pods. Attach to keda-demo-app-role (Day 13)."
  value       = aws_iam_policy.consumer.arn
}

output "keda_operator_policy_arn" {
  description = "IAM policy ARN for KEDA operator (read-only). Attach to keda-operator-role (Day 14)."
  value       = aws_iam_policy.keda_operator.arn
}

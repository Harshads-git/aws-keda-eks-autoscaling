# =============================================================================
# terraform/modules/sqs/main.tf — SQS Module
# =============================================================================
# Provisions SQS as Terraform-managed infrastructure (replaces scripts/setup-sqs.sh
# for the infrastructure lifecycle — the shell script still useful for quick testing).
#
# Resources created:
#   - Main SQS queue (long polling, visibility timeout configured)
#   - Dead Letter Queue (DLQ) for failed messages
#   - Redrive policy (after maxReceiveCount failures → DLQ)
#   - IAM policy for consumer pods (receive, delete, get attributes)
#   - IAM policy for KEDA operator (get attributes only — read-only)
#   - CloudWatch alarm for DLQ depth (alerts on poison messages)
#
# GCP equivalent (reference repo):
#   google_pubsub_topic + google_pubsub_subscription (Terraform resources)
#   This module is the AWS equivalent: aws_sqs_queue resources
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  queue_name  = var.queue_name != "" ? var.queue_name : "${local.name_prefix}-queue"
  dlq_name    = "${local.queue_name}-dlq"
}

# ── Dead Letter Queue ─────────────────────────────────────────────────────────
# Must be created BEFORE the main queue (main queue references DLQ ARN)
resource "aws_sqs_queue" "dlq" {
  name = local.dlq_name

  # Retain failed messages for 14 days for investigation
  message_retention_seconds = 1209600 # 14 days (maximum)

  tags = {
    Name    = local.dlq_name
    Purpose = "dead-letter-queue"
  }
}

# ── Main SQS Queue ────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  name = local.queue_name

  # ── Timing Configuration ───────────────────────────────────────────────────
  # visibility_timeout_seconds: How long a message is hidden after receive.
  # Must be >= your message processing time.
  # If processing takes >30s, the message reappears → duplicate processing.
  # Set to 2x your max processing time to be safe.
  visibility_timeout_seconds = var.visibility_timeout

  # Long polling: consumers wait up to 20s for messages (reduces API calls)
  # Cost impact: reduces ReceiveMessage API calls by ~20x vs short polling
  receive_wait_time_seconds = var.receive_wait_time

  # Message retention: how long SQS keeps unprocessed messages
  # 4 days default — increase to 14 days if consumers may be down for days
  message_retention_seconds = var.message_retention_seconds

  # ── Dead Letter Queue Configuration ───────────────────────────────────────
  # After maxReceiveCount delivery attempts, move message to DLQ
  # This prevents one bad message from blocking the entire queue
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = {
    Name    = local.queue_name
    Purpose = "keda-autoscaling-trigger"
  }
}

# ── IAM Policy: Consumer Pods ─────────────────────────────────────────────────
# Minimum permissions for app.py to receive and process messages.
# Attached to the IRSA role for consumer pods (keda-demo-app-role, Day 13).
#
# GCP equivalent: roles/pubsub.subscriber on the subscription
resource "aws_iam_policy" "consumer" {
  name        = "${local.name_prefix}-sqs-consumer-policy"
  description = "Allows consumer pods to receive and delete SQS messages"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSConsumerAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",         # Pull messages from queue
          "sqs:DeleteMessage",          # Delete after successful processing
          "sqs:ChangeMessageVisibility", # Extend visibility timeout if needed
          "sqs:GetQueueAttributes",     # Check queue depth (health checks)
          "sqs:GetQueueUrl",            # Resolve queue name to URL
        ]
        Resource = [
          aws_sqs_queue.main.arn,
          aws_sqs_queue.dlq.arn,
        ]
      }
    ]
  })

  tags = {
    Name    = "${local.name_prefix}-sqs-consumer-policy"
    Purpose = "irsa-consumer-pod"
  }
}

# ── IAM Policy: KEDA Operator ─────────────────────────────────────────────────
# KEDA only needs to READ the queue depth metric — nothing else.
# Principle of least privilege: KEDA cannot receive or delete messages.
# This is the permission boundary for keda-operator-role (Day 14).
#
# GCP equivalent: roles/monitoring.viewer on Cloud Monitoring metrics
resource "aws_iam_policy" "keda_operator" {
  name        = "${local.name_prefix}-sqs-keda-policy"
  description = "Allows KEDA operator to read SQS queue depth for autoscaling"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KEDAMetricAccess"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",  # Reads ApproximateNumberOfMessages
          "sqs:GetQueueUrl",         # Resolves queue name to URL
        ]
        Resource = [
          aws_sqs_queue.main.arn,
        ]
      }
    ]
  })

  tags = {
    Name    = "${local.name_prefix}-sqs-keda-policy"
    Purpose = "irsa-keda-operator"
  }
}

# ── CloudWatch Alarm: DLQ Depth ───────────────────────────────────────────────
# Triggers when messages land in the DLQ (indicates a processing bug).
# High DLQ depth = application bug, NOT a scaling problem.
# Feeds into an SNS topic for email/PagerDuty alerts (Day 24).
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${local.name_prefix}-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60  # 1-minute evaluation window
  statistic           = "Sum"
  threshold           = var.dlq_alarm_threshold

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  alarm_description = <<-EOF
    DLQ ${local.dlq_name} has messages — consumer is failing to process.
    Check application logs: kubectl logs -n keda-demo -l app.kubernetes.io/name=keda-demo
    Check DLQ messages: aws sqs receive-message --queue-url ${aws_sqs_queue.dlq.url}
  EOF

  # Populated on Day 24 when SNS topic is created:
  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${local.name_prefix}-dlq-alarm"
  }
}

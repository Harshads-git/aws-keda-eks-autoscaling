# =============================================================================
# terraform/modules/sqs/variables.tf
# =============================================================================

variable "project_name" {
  description = "Project name prefix for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)."
  type        = string
}

variable "queue_name" {
  description = "SQS queue name. Defaults to <project>-<env>-queue if empty."
  type        = string
  default     = ""
}

variable "visibility_timeout" {
  description = <<-EOF
    Seconds a message is hidden after ReceiveMessage.
    Set to 2x your max processing time to avoid duplicate processing.
    app.py processes messages in ~0.1s, but set conservatively to 30s.
  EOF
  type        = number
  default     = 30
}

variable "receive_wait_time" {
  description = "Long polling wait time (0-20s). 20s maximizes cost savings."
  type        = number
  default     = 20
}

variable "message_retention_seconds" {
  description = "How long SQS retains unprocessed messages (60-1209600s)."
  type        = number
  default     = 345600 # 4 days
}

variable "max_receive_count" {
  description = "Number of delivery attempts before message moves to DLQ."
  type        = number
  default     = 3
}

variable "dlq_alarm_threshold" {
  description = "Number of DLQ messages that triggers the CloudWatch alarm."
  type        = number
  default     = 1 # Alert on ANY DLQ message (zero-tolerance for failures)
}

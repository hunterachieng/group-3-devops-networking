variable "name_prefix" {
  description = "Resource name prefix shared across the lab stack."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to observability resources."
  type        = map(string)
}

variable "cluster_name" {
  description = "ECS cluster name for Container Insights metrics."
  type        = string
}

variable "order_service_name" {
  description = "ECS service name for the order service (saturation alarms)."
  type        = string
}

variable "load_balancer_arn_suffix" {
  description = "ALB arn_suffix dimension for CloudWatch (from alb module output)."
  type        = string
}

variable "order_target_group_arn_suffix" {
  description = "Order target group arn_suffix dimension for CloudWatch."
  type        = string
}

variable "order_log_group_name" {
  description = "CloudWatch log group for order service (log-based SLI metrics)."
  type        = string
}

variable "alert_email" {
  description = "Optional email address for SNS alarm notifications. Leave empty to create the topic without a subscription."
  type        = string
  default     = ""
}

variable "checkout_latency_p95_threshold_seconds" {
  description = "p95 ALB target response time threshold for the latency alarm."
  type        = number
  default     = 0.5
}

variable "order_cpu_threshold_percent" {
  description = "Order service CPU utilization threshold for the saturation alarm."
  type        = number
  default     = 80
}

variable "runbook_url" {
  description = "Link included in alarm descriptions (relative path or full URL)."
  type        = string
  default     = "production-readiness/04-runbook/runbook.md"
}

variable "slack_team_id" {
  description = "Slack workspace ID (T...) for AWS Chatbot. Leave empty to skip Slack."
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "Slack channel ID (C...) where alarms are posted. Leave empty to skip Slack."
  type        = string
  default     = ""
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for Lambda delivery. Leave empty to skip Lambda Slack."
  type        = string
  sensitive   = true
  default     = ""
}

variable "slack_channel_name" {
  description = "Slack channel name for webhook posts (e.g. #group-3-alerts)."
  type        = string
  default     = "#group-3-alerts"
}

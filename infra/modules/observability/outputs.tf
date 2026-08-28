output "sns_topic_arn" {
  description = "SNS topic ARN for production-readiness alarms."
  value       = aws_sns_topic.alerts.arn
}

output "sns_topic_name" {
  description = "SNS topic name for production-readiness alarms."
  value       = aws_sns_topic.alerts.name
}

output "dashboard_name" {
  description = "CloudWatch dashboard name for production readiness."
  value       = aws_cloudwatch_dashboard.production_readiness.dashboard_name
}

output "alarm_names" {
  description = "CloudWatch alarm names keyed by category."
  value = {
    checkout_availability = aws_cloudwatch_metric_alarm.checkout_availability_degraded.alarm_name
    checkout_latency      = aws_cloudwatch_metric_alarm.checkout_latency_high.alarm_name
    order_saturation      = aws_cloudwatch_metric_alarm.order_saturation_high.alarm_name
    unhealthy_targets     = aws_cloudwatch_metric_alarm.unhealthy_order_targets.alarm_name
  }
}

output "log_sli_namespace" {
  description = "Custom CloudWatch namespace for log-derived checkout SLI metrics."
  value       = "${var.name_prefix}/Checkout"
}

output "chatbot_enabled" {
  description = "Whether AWS Chatbot Slack delivery is configured."
  value       = local.chatbot_enabled
}

output "chatbot_configuration_name" {
  description = "AWS Chatbot Slack configuration name (empty when chatbot is disabled)."
  value       = local.chatbot_enabled ? aws_chatbot_slack_channel_configuration.alerts[0].configuration_name : ""
}

output "slack_lambda_enabled" {
  description = "Whether SNS alarms are forwarded to Slack via Lambda webhook."
  value       = nonsensitive(local.slack_lambda_enabled)
}

output "slack_lambda_function_name" {
  description = "Lambda function name for Slack notifications (empty when disabled)."
  value       = local.slack_lambda_enabled ? aws_lambda_function.slack_notifier[0].function_name : ""
}

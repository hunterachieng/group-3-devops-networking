output "vpc_id" {
  description = "Terraform-managed VPC ID."
  value       = module.network.vpc_id
}

output "alb_dns_name" {
  description = "Public DNS name for the internet-facing ALB."
  value       = module.alb.alb_dns_name
}

output "alb_url" {
  description = "HTTP URL for the ALB (health and checkout entry point)."
  value       = "http://${module.alb.alb_dns_name}"
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs_platform.cluster_name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = module.ecs_platform.cluster_arn
}

output "service_connect_namespace_arn" {
  description = "Service Connect private DNS namespace ARN."
  value       = module.ecs_platform.service_connect_namespace_arn
}

output "service_connect_namespace_name" {
  description = "Service Connect namespace name (group3.internal)."
  value       = module.ecs_platform.service_connect_namespace_name
}

output "order_target_group_arn" {
  description = "ALB target group ARN for the order service."
  value       = module.alb.order_target_group_arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by service name."
  value       = module.ecs_platform.repository_urls
}

output "service_names" {
  description = "ECS service names for order, inventory, and payment."
  value = {
    order     = module.order.service_name
    inventory = module.inventory.service_name
    payment   = module.payment.service_name
  }
}

output "deployed_images" {
  description = "Full image URIs selected by Terraform for each service."
  value = {
    order     = module.order.image
    inventory = module.inventory.image
    payment   = module.payment.image
  }
}

output "private_app_subnet_ids" {
  description = "Private subnet IDs where ECS tasks run."
  value       = module.network.private_app_subnet_ids
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint used for ECR layer downloads."
  value       = module.network.s3_gateway_endpoint_id
}

output "production_readiness_dashboard_name" {
  description = "CloudWatch dashboard for production readiness SLIs."
  value       = module.observability.dashboard_name
}

output "production_readiness_alarm_names" {
  description = "CloudWatch alarm names for production readiness."
  value       = module.observability.alarm_names
}

output "production_readiness_sns_topic_arn" {
  description = "SNS topic ARN for production readiness alarms."
  value       = module.observability.sns_topic_arn
}

output "production_readiness_chatbot_enabled" {
  description = "Whether CloudWatch alarms are wired to Slack via AWS Chatbot."
  value       = module.observability.chatbot_enabled
}

output "production_readiness_slack_lambda_enabled" {
  description = "Whether CloudWatch alarms are forwarded to Slack via Lambda webhook."
  value       = module.observability.slack_lambda_enabled
}

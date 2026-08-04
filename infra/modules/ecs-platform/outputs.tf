output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_connect_namespace_id" {
  description = "Cloud Map private DNS namespace ID."
  value       = aws_service_discovery_private_dns_namespace.this.id
}

output "service_connect_namespace_arn" {
  description = "Cloud Map private DNS namespace ARN for Service Connect."
  value       = aws_service_discovery_private_dns_namespace.this.arn
}

output "service_connect_namespace_name" {
  description = "Service Connect namespace name."
  value       = aws_service_discovery_private_dns_namespace.this.name
}

output "task_execution_role_arn" {
  description = "Task execution role ARN used by ECS to pull images and write logs."
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "Runtime task role ARN used by application containers."
  value       = aws_iam_role.task.arn
}

output "repository_urls" {
  description = "ECR repository URLs keyed by service name."
  value       = { for service, repo in aws_ecr_repository.service : service => repo.repository_url }
}

output "log_group_names" {
  description = "CloudWatch log group names keyed by service name."
  value       = { for service, log_group in aws_cloudwatch_log_group.service : service => log_group.name }
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ECS service ARN."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "Task definition ARN used by the service."
  value       = aws_ecs_task_definition.this.arn
}

output "security_group_id" {
  description = "Service security group ID."
  value       = aws_security_group.service.id
}

output "image" {
  description = "Full image URI deployed by this service."
  value       = local.image
}

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

output "assign_public_ip" {
  description = "Whether tasks receive public IPs. Must be false for private services."
  value       = var.assign_public_ip
}

output "ingress_rule_count" {
  description = "Number of security-group ingress rules defined for this service."
  value       = length(var.ingress_rules)
}

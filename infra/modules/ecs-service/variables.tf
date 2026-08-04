variable "name_prefix" {
  description = "Prefix used for service resources."
  type        = string
}

variable "service_key" {
  description = "Short service key, for example order, inventory, or payment."
  type        = string
}

variable "container_name" {
  description = "Container name used in the task definition and ALB mapping."
  type        = string
}

variable "container_port" {
  description = "HTTP port exposed by the application container."
  type        = number
}

variable "desired_count" {
  description = "Number of ECS tasks to keep running."
  type        = number
  default     = 1
}

variable "repository_url" {
  description = "ECR repository URL for this service."
  type        = string
}

variable "image_tag" {
  description = "Immutable image tag to deploy, normally sha-<commit>."
  type        = string

  validation {
    condition     = lower(var.image_tag) != "latest"
    error_message = "Use an immutable SHA tag, not latest."
  }
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the service security group."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs where Fargate tasks run."
  type        = list(string)
}

variable "task_execution_role_arn" {
  description = "IAM role ECS uses to pull images and write logs."
  type        = string
}

variable "task_role_arn" {
  description = "IAM role used by the running application task."
  type        = string
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "environment_variables" {
  description = "Application environment variables."
  type        = map(string)
  default     = {}
}

variable "log_group_name" {
  description = "CloudWatch log group name for the service."
  type        = string
}

variable "log_region" {
  description = "AWS region for awslogs."
  type        = string
}

variable "service_connect_namespace_arn" {
  description = "Service Connect namespace ARN."
  type        = string
}

variable "service_connect_discovery_name" {
  description = "Private DNS name advertised through Service Connect. Keep this aligned with application defaults such as order, inventory, and payment."
  type        = string
}

variable "port_name" {
  description = "Named port used by ECS Service Connect."
  type        = string
}

variable "assign_public_ip" {
  description = "Whether Fargate tasks receive public IPs. Keep false for private services."
  type        = bool
  default     = false
}

variable "alb_target_group_arn" {
  description = "Target group ARN when this service is exposed through the ALB. Leave null for internal services."
  type        = string
  default     = null
}

variable "ingress_rules" {
  description = "Security group ingress rules keyed by a stable caller-chosen name. Back-edge rules, such as payment to order callback, should be declared in the root module to avoid Terraform dependency cycles."
  type = map(object({
    description              = string
    from_port                = number
    to_port                  = number
    protocol                 = string
    source_security_group_id = string
  }))
  default = {}
}

variable "common_tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

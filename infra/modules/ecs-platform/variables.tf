variable "name_prefix" {
  description = "Prefix used for shared ECS resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where Service Connect private DNS namespace is created."
  type        = string
}

variable "namespace_name" {
  description = "Service Connect / Cloud Map namespace."
  type        = string
  default     = "group3.internal"
}

variable "service_keys" {
  description = "Service keys that need ECR repositories and log groups."
  type        = set(string)
  default     = ["order", "inventory", "payment"]
}

variable "log_retention_days" {
  description = "CloudWatch log retention for ECS service logs."
  type        = number
  default     = 14
}

variable "common_tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

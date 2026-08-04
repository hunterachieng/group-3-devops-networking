variable "name_prefix" {
  description = "Prefix used for ALB resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB and target group are created."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs in at least two AZs for the internet-facing ALB."
  type        = list(string)
}

variable "listener_port" {
  description = "Public HTTP listener port."
  type        = number
  default     = 80
}

variable "target_port" {
  description = "Order service container port registered in the target group."
  type        = number
  default     = 3001
}

variable "health_check_path" {
  description = "Health check path used by the target group."
  type        = string
  default     = "/health"
}

variable "allowed_ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach the ALB listener."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "common_tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

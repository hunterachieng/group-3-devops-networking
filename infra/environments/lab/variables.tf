variable "region" {
  description = "AWS region for the lab workload."
  type        = string
  default     = "us-west-1"

  validation {
    condition     = var.region == "us-west-1"
    error_message = "Lab workload must deploy in us-west-1 only."
  }
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "lab"
}

variable "name_prefix" {
  description = "Prefix for IaC-managed resources (distinct from console devops-g3-*)."
  type        = string
  default     = "devops-g3-iac"
}

variable "common_tags" {
  description = "Required tags applied to all resources."
  type        = map(string)
  default = {
    project     = "devops-g3"
    group       = "group-3"
    owner       = "group-3"
    environment = "lab"
  }

  validation {
    condition = alltrue([
      contains(keys(var.common_tags), "project"),
      contains(keys(var.common_tags), "group"),
      contains(keys(var.common_tags), "owner"),
      contains(keys(var.common_tags), "environment"),
    ])
    error_message = "common_tags must include project, group, owner, and environment."
  }
}

variable "order_image_tag" {
  description = "Immutable Git SHA for the order service image. Never use latest."
  type        = string
  default     = "REPLACE_ME"

  validation {
    condition     = lower(var.order_image_tag) != "latest"
    error_message = "order_image_tag must not be \"latest\". Use an immutable Git SHA."
  }

  validation {
    condition = (
      var.order_image_tag == "REPLACE_ME" ||
      can(regex("^[0-9a-fA-F]{7,40}$", var.order_image_tag))
    )
    error_message = "order_image_tag must be a Git SHA (7-40 hex characters) or REPLACE_ME until the first ECR push."
  }
}

variable "inventory_image_tag" {
  description = "Immutable Git SHA for the inventory service image. Never use latest."
  type        = string
  default     = "REPLACE_ME"

  validation {
    condition     = lower(var.inventory_image_tag) != "latest"
    error_message = "inventory_image_tag must not be \"latest\". Use an immutable Git SHA."
  }

  validation {
    condition = (
      var.inventory_image_tag == "REPLACE_ME" ||
      can(regex("^[0-9a-fA-F]{7,40}$", var.inventory_image_tag))
    )
    error_message = "inventory_image_tag must be a Git SHA (7-40 hex characters) or REPLACE_ME until the first ECR push."
  }
}

variable "payment_image_tag" {
  description = "Immutable Git SHA for the payment service image. Never use latest."
  type        = string
  default     = "REPLACE_ME"

  validation {
    condition     = lower(var.payment_image_tag) != "latest"
    error_message = "payment_image_tag must not be \"latest\". Use an immutable Git SHA."
  }

  validation {
    condition = (
      var.payment_image_tag == "REPLACE_ME" ||
      can(regex("^[0-9a-fA-F]{7,40}$", var.payment_image_tag))
    )
    error_message = "payment_image_tag must be a Git SHA (7-40 hex characters) or REPLACE_ME until the first ECR push."
  }
}

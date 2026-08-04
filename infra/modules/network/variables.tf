variable "name_prefix" {
  description = "Prefix used for all network resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.30.0.0/16"
}

variable "public_subnets" {
  description = "Public subnet plan keyed by a short AZ label."
  type = map(object({
    availability_zone = string
    cidr_block        = string
  }))
  default = {
    a = {
      availability_zone = "us-west-1a"
      cidr_block        = "10.30.0.0/24"
    }
    c = {
      availability_zone = "us-west-1c"
      cidr_block        = "10.30.1.0/24"
    }
  }
}

variable "private_app_subnets" {
  description = "Private application subnet plan keyed by a short AZ label."
  type = map(object({
    availability_zone = string
    cidr_block        = string
  }))
  default = {
    a = {
      availability_zone = "us-west-1a"
      cidr_block        = "10.30.10.0/24"
    }
    c = {
      availability_zone = "us-west-1c"
      cidr_block        = "10.30.11.0/24"
    }
  }
}

variable "interface_endpoint_services" {
  description = "AWS interface VPC endpoints required by private ECS tasks."
  type        = set(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "sts",
    "ssmmessages"
  ]
}

variable "endpoint_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach interface endpoints on HTTPS."
  type        = list(string)
  default     = ["10.30.0.0/16"]
}

variable "common_tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

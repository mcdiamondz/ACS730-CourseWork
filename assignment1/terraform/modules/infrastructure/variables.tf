variable "aws_region" {
  description = "Region to build in."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod). Used for naming and tags."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "acs730-a1"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.project))
    error_message = "project: 3-24 lowercase letters, digits, hyphens, starting with a letter."
  }
}

variable "owner" {
  description = "Your Seneca username. Tagged onto everything. No default on purpose."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.42.0.0/16"
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR, for example 10.42.0.0/16."
  }
}

variable "public_subnets" {
  description = "Public subnets to create, keyed by a short stable name."
  type = map(object({
    cidr_block = string
    az_index   = number
  }))
  default = {
    a = { cidr_block = "10.42.1.0/24", az_index = 0 }
    b = { cidr_block = "10.42.2.0/24", az_index = 1 }
  }
}

variable "ingress_rules" {
  description = "Ingress rules for the web security group, rendered by a dynamic block."
  type = list(object({
    description = string
    port        = number
    cidr_blocks = list(string)
  }))
  default = [
    { description = "HTTP from anywhere", port = 80, cidr_blocks = ["0.0.0.0/0"] },
  ]
}

variable "instance_type" {
  description = "Instance type for the web server."
  type        = string
  default     = "t3.micro"
  validation {
    condition     = contains(["t3.micro", "t3.small"], var.instance_type)
    error_message = "Stay small: t3.micro or t3.small. The term budget is $50 in total."
  }
}

variable "instance_count" {
  description = "Number of web server instances."
  type        = number
  default     = 2
  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 3
    error_message = "instance_count must be between 1 and 3."
  }
}

variable "create_artifact_bucket" {
  description = "Create the optional artifact bucket. Gated with count, not for_each."
  type        = bool
  default     = false
}

variable "ssm_parameter_name" {
  description = "Name of the SSM parameter to read for application configuration."
  type        = string
  default     = "/acs730/a1/db_password"
}

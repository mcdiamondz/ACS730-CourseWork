data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project}-${var.owner}-${var.environment}"

  # Single source of truth for "where did this run actually point"
  provider_target = "aws (${data.aws_region.current.name})"

  # Fold the AZ lookup in here, so the resource block below has no logic
  public_subnets = {
    for key, cfg in var.public_subnets : key => {
      cidr_block        = cfg.cidr_block
      availability_zone = data.aws_availability_zones.available.names[cfg.az_index]
    }
  }

  common_tags = {
    Managed = "terraform"
    Lab     = "assignment1"
    Environment = var.environment
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

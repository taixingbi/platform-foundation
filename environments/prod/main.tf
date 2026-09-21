terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  name_prefix = "gateway-prod"
}

# Platform restructuring Phase 3 (2026-09-21): moved here from
# bedrock-runtime-gateway/infra -- unlike dev, prod's network was
# never actually applied there (0 resources in that repo's prod
# state before this move, confirmed live), so this is a config-only
# mirror, not a state migration -- "hold prod" (mirror config, never
# apply) still applies here same as everywhere else in this platform.
module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  environment = "prod"
  aws_region  = var.aws_region
}

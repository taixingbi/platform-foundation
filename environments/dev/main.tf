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
  name_prefix = "gateway-dev"
}

# Platform restructuring Phase 3 (2026-09-21): moved here from
# bedrock-runtime-gateway/infra, WITHOUT touching any live resource --
# same state-mv/push playbook used for every other cross-repo
# ownership move in this platform (authz-service's ECS/ALB, portal/
# cognito). Every other repo already looks up this VPC's real
# resources by NAME (e.g. data "aws_lb" "gateway" { name =
# "gateway-dev-alb" } -> .vpc_id), never by referencing this module
# directly -- so this move changes nothing about how any other repo's
# Terraform resolves the VPC, only who owns its lifecycle.
module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  environment = "dev"
  aws_region  = var.aws_region
}

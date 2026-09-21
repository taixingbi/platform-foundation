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

# --- Shared internal Private CA (Phase 3c, 2026-09-21) --------------------
#
# Moved here from bedrock-runtime-gateway/infra, WITHOUT touching any
# live resource -- same state-mv/push playbook used for every other
# cross-repo ownership move in this platform. Every repo that needs
# this CA already hardcodes its ARN as a literal string (e.g.
# platform-authz-service/environments/dev/main.tf's local.private_ca_arn)
# rather than a module reference or data source -- ACM PCA has no
# clean "look up by name/tag" data source the way VPC/ALB/etc. do, and
# a private CA's ARN never changes for its lifetime. This move changes
# nothing about how any repo resolves the CA, only who owns its
# lifecycle.
#
# Real recurring cost: ~$400/month (ACM Private CA's own price, not
# usage-based) -- already being paid for before this move, not new
# spend.
resource "aws_acmpca_certificate_authority" "internal" {
  type = "ROOT"

  certificate_authority_configuration {
    key_algorithm     = "RSA_2048"
    signing_algorithm = "SHA256WITHRSA"

    subject {
      common_name = "Bedrock Gateway Platform Internal CA"
    }
  }

  # Minimum allowed -- no benefit to a longer grace period for
  # infrastructure like this, and every extra day is another day of
  # possible billing on a CA nobody meant to keep.
  permanent_deletion_time_in_days = 7
}

resource "aws_acmpca_certificate" "internal_root" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.internal.arn
  certificate_signing_request = aws_acmpca_certificate_authority.internal.certificate_signing_request
  signing_algorithm           = "SHA256WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = 10
  }
}

resource "aws_acmpca_certificate_authority_certificate" "internal" {
  certificate_authority_arn = aws_acmpca_certificate_authority.internal.arn
  certificate               = aws_acmpca_certificate.internal_root.certificate
  certificate_chain         = aws_acmpca_certificate.internal_root.certificate_chain
}

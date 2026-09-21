# Account-wide resources: the GitHub OIDC provider (the one resource
# here every other repo's own CI depends on, referenced everywhere
# else only via data source) plus this repo's own CI roles
# (plan/apply-dev, below).
#
# Terraform-ownership migration (2026-09-21): every other repo's own
# CI roles used to live here too (app, infra, authz, control-plane,
# edge-gateway, policies) -- each has since moved to its own
# ci_identity root in its own repo, imported there via `terraform
# import` (never delete/recreate), so ARNs and GitHub Environment
# variables never changed. Only the OIDC provider singleton and this
# repo's own roles stay here permanently: a bad apply against any
# other repo's own ci_identity now only risks that one repo's CI, not
# every repo's at once.
#
# bedrock-gateway-portal's own roles (gha-portal-deploy-dev/prod) were
# removed outright (not migrated) on 2026-09-21, once
# platform-control-plane's own portal was confirmed live -- verified
# the running gateway-dev-portal-service task was already built from
# platform-control-plane's own CI, and bedrock-gateway-portal is
# archived on GitHub (can no longer deploy at all).

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
  foundation_repo = "platform-foundation"
}

# --- This repo's own CI (plan-only, no auto-apply anywhere -- every
# apply against this repo's three environments stays a manual hand-off,
# unlike every other repo's dev auto-apply, since this is the repo that
# owns the OIDC provider itself, every other repo's deploy/plan/apply
# roles, the shared VPC/network, and the Private CA: the blast radius
# of a bad auto-apply here is much larger than a normal service). One
# read-only role, reused across all three environments' plan jobs --
# the AWS role itself doesn't care which environment/ directory it's
# invoked from, only the policy below scopes what it can read. --------

data "aws_iam_policy_document" "foundation_plan" {
  statement {
    sid = "ReadOnly"
    actions = [
      # modules/network: VPC, subnets, route tables, IGW/NAT/EIP, the
      # two gateway VPC endpoints.
      "ec2:Describe*",
      # modules/github_oidc: the OIDC provider itself, plus this
      # repo's own role + inline policy (the only ones left here).
      "iam:Get*", "iam:List*",
      # environments/dev's Private CA (aws_acmpca_certificate_authority
      # + the self-signed root cert issued from it).
      "acm-pca:Describe*", "acm-pca:Get*", "acm-pca:List*",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "TerraformStateS3"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
}

# dev auto-apply, matching every other repo's convention -- deliberately
# scoped to ONLY environments/dev's own resources (network + the Private
# CA), never iam:*/ManageOidcProvider (those live in environments/global,
# which stays plan-only/manual -- no equivalent to "prod" risk-wise in
# any other repo, since a bad apply there can affect every other repo's
# own CI, not just this one). environments/prod stays plan-only too
# (never applied, per this account's standing "hold prod" convention).
data "aws_iam_policy_document" "foundation_apply_dev" {
  statement {
    sid       = "Ec2Broad"
    actions   = ["ec2:*"]
    resources = ["*"]
  }
  statement {
    sid       = "AcmPcaBroad"
    actions   = ["acm-pca:*"]
    resources = ["*"]
  }
  statement {
    sid       = "TerraformStateS3"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
}

module "github_oidc_foundation" {
  source = "../../modules/github_oidc"

  # Terraform-ownership migration, step 4 of 6 (2026-09-21): the
  # account-wide OIDC provider singleton's ownership moved here from
  # module.github_oidc_infra (which formally adopted it via import back
  # in Phase 3c -- created 2026-09-12 by the original, now-archived
  # bedrock-gateway-platform repo) via `terraform state mv`, not
  # delete/recreate -- this module call never migrates to another repo,
  # unlike github_oidc_infra's own roles, so it's the permanent home for
  # the one resource every other repo's module call reads via data
  # source. Picked deliberately this time (not arbitrarily, unlike the
  # original Phase 3c pick) specifically because this module stays.
  create_oidc_provider = true
  github_org           = var.github_org
  github_repo          = local.foundation_repo

  roles = {
    plan = {
      role_name   = "gha-foundation-plan"
      policy_json = data.aws_iam_policy_document.foundation_plan.json
    }
    apply-dev = {
      role_name   = "gha-foundation-apply-dev"
      policy_json = data.aws_iam_policy_document.foundation_apply_dev.json
    }
  }
}

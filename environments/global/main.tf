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
# The only other thing left here is bedrock-gateway-portal's roles
# (module.github_oidc_portal, below) -- deliberately NOT migrated,
# since that whole repo gets deleted outright once
# platform-control-plane's own portal cutover completes, not moved
# anywhere.

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

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Not renamed -- superseded by platform-control-plane's own portal,
  # not yet cut over live; stays bedrock-gateway-portal until that
  # repo is deprecated.
  portal_repo     = "bedrock-gateway-portal"
  foundation_repo = "platform-foundation"
}

# --- Portal repo (M10): push to ECR, register+deploy a task
# definition -- no PassRole for a task role, unlike bedrock-runtime-gateway's
# own app_deploy (now in that repo's own ci_identity): portal_service
# has no task IAM role at all (the portal never calls an AWS API
# directly, only the gateway's own HTTP admin API), so there's no task
# role ARN to pass. Temporary -- this whole role (and the
# bedrock-gateway-portal repo it belongs to) gets deleted outright,
# not migrated, once platform-control-plane's own portal cutover is
# complete. ---------------------------

data "aws_iam_policy_document" "portal_deploy" {
  for_each = { dev = "gateway-dev-portal", prod = "gateway-prod-portal" }

  statement {
    sid = "PushToEcr"
    actions = [
      "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${each.value}*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "DeployToEcs"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "ecs:cluster"
      values   = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:cluster/${each.value}*"]
    }
  }

  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "PassExecutionRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${each.value}*-execution"]
  }
}

module "github_oidc_portal" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.portal_repo

  roles = {
    dev = {
      role_name   = "gha-portal-deploy-dev"
      policy_json = data.aws_iam_policy_document.portal_deploy["dev"].json
    }
    prod = {
      role_name   = "gha-portal-deploy-prod"
      policy_json = data.aws_iam_policy_document.portal_deploy["prod"].json
    }
  }
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
      # modules/github_oidc: the OIDC provider itself, plus every role
      # + inline policy this repo still manages directly (its own,
      # and bedrock-gateway-portal's temporary ones).
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

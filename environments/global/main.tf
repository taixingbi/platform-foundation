# Account-wide resources: the GitHub OIDC provider (created once, here)
# and every OIDC role across all three split repos -- this repo owns
# IAM/OIDC for the whole platform, even though the app and policies
# repos' own CI is what actually assumes these roles. Apply this once
# per AWS account, before any of the three repos' CI can authenticate
# (see README.md for the required apply order, including the
# chicken-and-egg first-ever apply of this repo's own infra-apply role).

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

  policies_repo = "platform-policy-definitions"
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

# --- Policies repo: write-only to wherever policy delivery ends up.
# Phase 1 (interim, current) has nothing for this role to actually do --
# delivery is a manual copy into the app repo, not an automated publish.
# Scoped ahead of time to phase 2's planned DynamoDB table name so the
# trust relationship/role identity already exists; inert until that
# table does. -----------------------------------------------------------

data "aws_iam_policy_document" "policy_publish" {
  statement {
    sid       = "PublishToPolicyTable"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DescribeTable"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/gateway-policies"]
  }
}

module "github_oidc_policies" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.policies_repo

  roles = {
    publish = {
      role_name   = "gha-policy-publish"
      policy_json = data.aws_iam_policy_document.policy_publish.json
    }
  }

  # Ensures the account-wide OIDC provider (now owned by
  # module.github_oidc_foundation, moved there from this repo's former
  # module.github_oidc_app in the Terraform-ownership migration) exists
  # before this role's own data-source lookup of it, avoiding a
  # first-ever-apply ordering race.
  depends_on = [module.github_oidc_foundation]
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
      # modules/github_oidc: the OIDC provider itself, every role +
      # inline policy this repo manages across all seven module calls.
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

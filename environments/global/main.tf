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

  # Platform restructuring Phase 2 (2026-09-21): bedrock-runtime-gateway-app
  # and bedrock-runtime-gateway-infra merged into this one repo
  # (bedrock-runtime-gateway, app/ and infra/ subfolders) -- this file
  # itself is now IN that merged repo, at infra/environments/global.
  # ONE local instead of two, since github_oidc_app's deploy-{dev,prod}
  # roles and github_oidc_infra's plan/apply-dev/apply-prod roles now
  # trust the SAME repo, just different GitHub Environments within it.
  # These locals MUST track each repo's CURRENT GitHub name exactly,
  # since it feeds every role's trust policy sub condition
  # (modules/github_oidc/main.tf) directly. A stale value here doesn't
  # error at plan/apply time; it silently 403s that repo's CI the next
  # time it tries to assume its role.
  runtime_gateway_repo = "bedrock-runtime-gateway"
  policies_repo        = "platform-policy-definitions"
  # Not renamed -- superseded by platform-control-plane's own portal,
  # not yet cut over live; stays bedrock-gateway-portal until that
  # repo is deprecated.
  portal_repo     = "bedrock-gateway-portal"
  foundation_repo = "platform-foundation"
}

# --- App repo: push to ECR, deploy to ECS. Same shape this account
# already ran (and verified end to end) as the combined repo's
# "gha-deploy-{dev,prod}" roles, just renamed/re-scoped to the app
# repo's own OIDC trust. ---------------------------------------------

data "aws_iam_policy_document" "app_deploy" {
  for_each = { dev = "gateway-dev", prod = "gateway-prod" }

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

  # Not cluster-scoped (task definitions are cluster-independent), so
  # the ecs:cluster condition above can't apply to these two.
  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid     = "PassEcsRoles"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${each.value}*-execution",
      "arn:aws:iam::${local.account_id}:role/${each.value}*-task",
    ]
  }
}

module "github_oidc_app" {
  source = "../../modules/github_oidc"

  # The account-wide OIDC provider already exists (created by the
  # original bedrock-gateway-platform repo's environments/global apply,
  # before the app/infra/policies split) -- every call here references
  # it via data source rather than trying to create a second one for
  # the same URL, which AWS rejects as a duplicate.
  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.runtime_gateway_repo

  roles = {
    dev = {
      role_name   = "gha-app-deploy-dev"
      policy_json = data.aws_iam_policy_document.app_deploy["dev"].json
    }
    prod = {
      role_name   = "gha-app-deploy-prod"
      policy_json = data.aws_iam_policy_document.app_deploy["prod"].json
    }
  }
}

# --- Portal repo (M10): same shape as app_deploy above, minus
# PassRole -- portal_service has no task IAM role at all (the portal
# never calls an AWS API directly, only the gateway's own HTTP admin
# API), so there's no task role ARN to pass. ---------------------------

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

# --- This repo (infra): Terraform plan (read-only, safe on every PR)
# and apply (read-write, merge-only). Most of the services this repo's
# Terraform manages (EC2/VPC, ELBv2, ECS, ECR, API Gateway v2) don't
# support resource-level IAM scoping on their creation actions -- a
# vpc/subnet/security-group/ALB/etc. ARN doesn't exist until after
# it's created, so IAM can't restrict *which* one a CreateX call is
# allowed to make. Broad service-level grants (Resource "*") for those
# is standard practice for a Terraform CI role, not an oversight; IAM
# role management and the Terraform state backend *do* support real
# resource scoping, so those are scoped by name below. Tighten further
# once you've seen exactly what `apply` actually calls in practice. ---

data "aws_iam_policy_document" "infra_plan" {
  statement {
    sid = "ReadOnly"
    actions = [
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "ecs:Describe*", "ecs:List*",
      "ecr:Describe*", "ecr:List*", "ecr:GetLifecyclePolicy",
      "apigateway:GET",
      "logs:Describe*", "logs:List*",
      "iam:Get*", "iam:List*",
      "sts:GetCallerIdentity",
      # Describe*, not just DescribeTable: refreshing an
      # aws_dynamodb_table's full state also calls
      # DescribeContinuousBackups (PITR), DescribeTimeToLive, etc --
      # same "Describe*" wildcard already used for every other service
      # in this statement, for the same reason.
      "dynamodb:GetItem", "dynamodb:Describe*", "dynamodb:ListTagsOfResource",
      "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ListQueues", "sqs:ListQueueTags",
      "s3:GetObject", "s3:ListBucket",
      # aws_s3_bucket + its sub-resources (public access block,
      # encryption, lifecycle, CORS, ...) call many distinct Get*
      # bucket-config actions on refresh -- learned live over four
      # separate 403s chasing one action at a time (GetBucketPolicy,
      # GetBucketAcl, GetBucketCORS, ...), so this is the wildcard
      # instead of a fifth one-at-a-time fix -- same "Get*" convention
      # already used below for cognito-idp/cloudfront/acm in this same
      # statement.
      "s3:Get*",
      # Bedrock guardrail refresh (aws_bedrock_guardrail.this) -- same
      # reasoning, discovered live alongside the S3 gaps above.
      "bedrock:Get*", "bedrock:List*",
      # Refreshing aws_cognito_user/aws_cognito_user_in_group state
      # calls the Admin* variants (AdminGetUser,
      # AdminListGroupsForUser), a separate action namespace from
      # Get*/List* despite reading the same data.
      "cognito-idp:Describe*", "cognito-idp:Get*", "cognito-idp:List*",
      "cognito-idp:AdminGetUser", "cognito-idp:AdminListGroupsForUser",
      "cloudfront:Get*", "cloudfront:List*",
      # Not covered by ec2:Describe* -- a distinct action name for the
      # same read, needed to plan module.portal_service's prefix-list
      # ingress rule.
      "ec2:GetManagedPrefixListEntries",
      # Internal TLS (gateway-api <-> authz-service): the private CA
      # and the ACM cert it issues.
      "acm-pca:Describe*", "acm-pca:Get*", "acm-pca:List*",
      "acm:Describe*", "acm:Get*", "acm:List*",
      # Plan section 35's P0/P2 production hardening (autoscaling,
      # CloudWatch alarms, the ops_alerts SNS topic, the audit KMS
      # key) -- same class of gap as every prior addition to this
      # ReadOnly statement: the apply role got the create/manage
      # grant when each feature was built, but the separate, narrower
      # plan role was never given the matching read-only permission,
      # so `terraform plan` 403s refreshing state for a resource
      # `apply` already created fine. Discovered across two rounds
      # live (application-autoscaling:ListTagsForResource and all of
      # cloudwatch: were missed on the first pass -- Describe* alone
      # doesn't cover a distinct-verb action like ListTagsForResource,
      # same lesson as cognito-idp's Admin* actions above).
      "application-autoscaling:Describe*", "application-autoscaling:ListTagsForResource",
      "cloudwatch:Describe*", "cloudwatch:List*", "cloudwatch:Get*",
      "sns:GetTopicAttributes", "sns:ListTagsForResource", "sns:ListTopics",
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
      "kms:ListResourceTags", "kms:ListAliases",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "infra_apply" {
  statement {
    sid       = "Ec2Broad"
    actions   = ["ec2:*"]
    resources = ["*"]
  }
  statement {
    sid       = "ElbBroad"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }
  statement {
    sid       = "EcsBroad"
    actions   = ["ecs:*"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrBroad"
    actions   = ["ecr:*"]
    resources = ["*"]
  }
  statement {
    sid       = "ApiGatewayBroad"
    actions   = ["apigateway:*"]
    resources = ["*"]
  }
  statement {
    sid       = "LogsBroad"
    actions   = ["logs:*"]
    resources = ["*"]
  }
  # M7: SQS/DynamoDB resource ARNs (queue URL, table name) don't exist
  # until creation, same reasoning as every other broad grant above --
  # not scopable ahead of time.
  statement {
    sid       = "SqsBroad"
    actions   = ["sqs:*"]
    resources = ["*"]
  }
  statement {
    sid       = "DynamoDbBroad"
    actions   = ["dynamodb:*"]
    resources = ["*"]
  }
  # M10 Cognito task: User Pool/domain/client/group ids don't exist
  # until creation either -- same reasoning as SqsBroad/DynamoDbBroad.
  statement {
    sid       = "CognitoBroad"
    actions   = ["cognito-idp:*"]
    resources = ["*"]
  }
  # CloudFront distribution ids likewise don't exist until creation;
  # ListCachePolicies/ListOriginRequestPolicies (looking up AWS's
  # managed policies by name) need read access even during plan.
  statement {
    sid       = "CloudFrontBroad"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }
  # Internal TLS (gateway-api <-> authz-service): creating/activating
  # the private CA and issuing authz-service's ALB cert from it. Learned
  # live -- the first apply attempting this 403'd, since neither
  # acm-pca:* nor acm:* had ever been granted before this.
  statement {
    sid       = "AcmPcaBroad"
    actions   = ["acm-pca:*"]
    resources = ["*"]
  }
  statement {
    sid       = "AcmBroad"
    actions   = ["acm:*"]
    resources = ["*"]
  }

  # IAM role names ARE predictable ahead of time (unlike VPC/ALB/etc.
  # IDs), so this one can actually be scoped by name.
  statement {
    sid = "ManageGatewayAndOidcRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies", "iam:TagRole", "iam:UntagRole", "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/gateway-*",
      "arn:aws:iam::${local.account_id}:role/gha-*",
    ]
  }
  statement {
    sid = "ManageOidcProvider"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders", "iam:DeleteOpenIDConnectProvider",
    ]
    # The provider resource's ARN is account+host, not name-based --
    # nothing narrower to scope this to.
    resources = ["*"]
  }
  statement {
    sid = "TerraformStateS3"
    # S3-native state locking (use_lockfile in every backend.tf, replacing
    # the deprecated dynamodb_table): DeleteObject releases the <key>.tflock
    # object an apply creates to hold the lock. Not needed by any *_plan
    # role above -- every plan job always runs with -lock=false, so it
    # never touches the lock file at all.
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
  # S3AuditStore's bucket (gateway-{dev,prod}-audit) -- learned live, the
  # first apply attempting this 403'd, since no S3 permission beyond the
  # tfstate backend bucket had ever been granted before this. Bucket
  # name IS predictable (this app's own naming convention), so scoped
  # by name rather than "*" like the tfstate grant above would need to
  # be if extended here too.
  #
  # Widened from "gateway-*-audit" to "gateway-*-audit*" for
  # S3RequestAuditStore's bucket (gateway-{dev,prod}-audit-immutable,
  # plan section 34.4) -- learned live the same way: the first apply
  # attempting to create it 403'd on s3:CreateBucket, this resource
  # pattern didn't match the "-immutable" suffix.
  statement {
    sid       = "S3AuditBucketBroad"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::gateway-*-audit*", "arn:aws:s3:::gateway-*-audit*/*"]
  }
  # BedrockGuardrailClient's aws_bedrock_guardrail -- learned live, the
  # first apply 403'd on bedrock:TagResource (the resource sets tags).
  # Guardrail ids don't exist until creation, same "*" reasoning as
  # SqsBroad/DynamoDbBroad/CognitoBroad above.
  statement {
    sid = "BedrockGuardrailBroad"
    actions = [
      "bedrock:CreateGuardrail", "bedrock:CreateGuardrailVersion", "bedrock:UpdateGuardrail",
      "bedrock:DeleteGuardrail", "bedrock:GetGuardrail", "bedrock:ListGuardrails",
      "bedrock:TagResource", "bedrock:UntagResource", "bedrock:ListTagsForResource",
    ]
    resources = ["*"]
  }
  # Plan section 35.6 (P0 production hardening): ECS service
  # autoscaling targets/policies and the CloudWatch alarms driving the
  # worker's step-scaling. Neither was ever granted before this --
  # same "resource ids don't exist until creation" reasoning as every
  # other broad grant here, application-autoscaling's own resource_id
  # is a composite string (service/cluster/service-name), not a
  # separately scopable ARN.
  statement {
    sid       = "AppAutoscalingBroad"
    actions   = ["application-autoscaling:*"]
    resources = ["*"]
  }
  statement {
    sid       = "CloudWatchBroad"
    actions   = ["cloudwatch:*"]
    resources = ["*"]
  }
  # Plan section 35's P1 hardening: an SNS topic for CloudWatch alarm
  # notifications (5xx rate, latency, DLQ depth, ...) -- never granted
  # before this. Topic ARNs don't exist until creation, same "*"
  # reasoning as every other broad grant here.
  statement {
    sid       = "SnsBroad"
    actions   = ["sns:*"]
    resources = ["*"]
  }
  # application-autoscaling needs an IAM service-linked role to
  # actually call ecs:UpdateService on the platform's behalf --
  # created automatically on first use IF the caller has this
  # permission; scoped to the one service-linked role name AWS uses
  # for this, not IamBroad.
  statement {
    sid       = "AppAutoscalingServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.application-autoscaling.amazonaws.com"]
    }
  }
  # Plan section 35.12 (P2 production hardening): a shared CMK for both
  # audit buckets (SSE-KMS instead of SSE-S3/AES256, for CloudTrail
  # attribution of who decrypted/generated a data key). Key ids/aliases
  # don't exist until creation, same "*" reasoning as every other broad
  # grant here.
  statement {
    sid       = "KmsBroad"
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

module "github_oidc_infra" {
  source = "../../modules/github_oidc"

  # Terraform-ownership migration, step 4 of 6 (2026-09-21): this
  # module's roles are moving to bedrock-runtime-gateway's own
  # ci_identity, but the account-wide OIDC provider singleton must stay
  # in this repo -- ownership of that ONE resource moved to
  # module.github_oidc_foundation (via `terraform state mv`, see that
  # module's own comment), which never leaves. This call now only ever
  # references the provider via data source, same as every other call
  # here.
  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.runtime_gateway_repo

  roles = {
    plan = {
      role_name   = "gha-infra-plan"
      policy_json = data.aws_iam_policy_document.infra_plan.json
    }
    # Split dev/prod so the OIDC trust condition itself enforces the
    # separation, not just the GitHub Environment's approval UI: a job
    # whose sub claim says "environment:apply-dev" cannot assume
    # gha-infra-apply-prod's role even if someone edited the workflow
    # to skip the required-reviewer gate. Same policy document for both
    # for now (TODO: scope prod's role tighter than dev's once there's
    # something concrete to restrict it to).
    apply-dev = {
      role_name   = "gha-infra-apply-dev"
      policy_json = data.aws_iam_policy_document.infra_apply.json
    }
    apply-prod = {
      role_name   = "gha-infra-apply-prod"
      policy_json = data.aws_iam_policy_document.infra_apply.json
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

  depends_on = [module.github_oidc_app]
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

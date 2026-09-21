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
  portal_repo = "bedrock-gateway-portal"
  # Named "platform-*", not "bedrock-*" -- both are provider-agnostic
  # infrastructure (principal mapping/RBAC, HTTP API front door) that
  # any future non-Bedrock AI-provider gateway on this platform could
  # share, unlike bedrock-runtime-gateway above, which is genuinely
  # Bedrock-specific application code.
  api_gateway_repo   = "platform-edge-gateway"
  control_plane_repo = "platform-control-plane"
  foundation_repo    = "platform-foundation"
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

# --- platform-control-plane repo, Phase 1 (portal/cognito infra
# ownership -- see migrate-control-plane-infra-state.sh): this repo's
# own Terraform plan/apply-dev roles, same shape as
# authz_infra_plan/apply above, plus its OWN portal deploy-dev role
# (push image, update the SAME live gateway-dev-portal* ECS service
# the old bedrock-gateway-portal repo's gha-portal-deploy-dev role
# already deploys to -- identical policy shape, just scoped to this
# repo's OIDC trust instead). No backend (admin/onboarding) deploy
# role yet -- that service doesn't have real ECS infra until the
# cutover design (blue-green vs cutover timing) is decided; adding an
# inert role scoped to resource names that don't exist yet would just
# be guessing. --------------------------------------------------------

data "aws_iam_policy_document" "control_plane_infra_plan" {
  statement {
    sid = "ReadOnly"
    actions = [
      "ec2:Describe*",
      # Learned live 2026-09-21 fixing the portal outage: refreshing
      # modules/portal_service's data "aws_ec2_managed_prefix_list"
      # "cloudfront_origin_facing" calls this specific action, a
      # distinct verb Describe* doesn't cover -- same gap
      # api_gateway_plan's own WafReadOnly-adjacent comment already
      # documents for a different data source in platform-edge-gateway.
      "ec2:GetManagedPrefixListEntries",
      "elasticloadbalancing:Describe*",
      "ecs:Describe*", "ecs:List*",
      "ecr:Describe*", "ecr:List*", "ecr:GetLifecyclePolicy",
      "cloudfront:Get*", "cloudfront:List*",
      "cognito-idp:Describe*", "cognito-idp:Get*", "cognito-idp:List*",
      "cognito-idp:AdminGetUser", "cognito-idp:AdminListGroupsForUser",
      "logs:Describe*", "logs:List*",
      "iam:Get*", "iam:List*",
      "sts:GetCallerIdentity",
      "application-autoscaling:Describe*", "application-autoscaling:ListTagsForResource",
      "cloudwatch:Describe*", "cloudwatch:List*", "cloudwatch:Get*",
      # Phase 4 (2026-09-21, "direct cutover"): backend_service's own
      # cross-repo lookups (the ops_alerts SNS topic, the 7 DynamoDB
      # tables it reads/writes) -- learned live the same way
      # ec2:GetManagedPrefixListEntries was above: Describe*/Get*
      # doesn't cover sns:ListTopics or dynamodb:ListTagsOfResource,
      # DynamoDB's own break from the usual naming convention (same
      # gap authz_infra_plan's own ReadOnly statement already
      # documents).
      "sns:GetTopicAttributes", "sns:ListTopics", "sns:ListTagsForResource",
      "dynamodb:Describe*", "dynamodb:ListTagsOfResource",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "TerraformStateS3"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
}

data "aws_iam_policy_document" "control_plane_infra_apply" {
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
    sid       = "CloudFrontBroad"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }
  statement {
    sid       = "CognitoBroad"
    actions   = ["cognito-idp:*"]
    resources = ["*"]
  }
  statement {
    sid       = "LogsBroad"
    actions   = ["logs:*"]
    resources = ["*"]
  }
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
  # Read-only: bedrock-runtime-gateway owns both the ops_alerts SNS
  # topic and the 7 DynamoDB tables backend_service reads/writes --
  # this repo only ever looks them up by name (data source), never
  # manages their lifecycle. Same convention as authz_infra_apply's
  # identical statements.
  statement {
    sid       = "SnsReadOnly"
    actions   = ["sns:GetTopicAttributes", "sns:ListTopics", "sns:ListTagsForResource"]
    resources = ["*"]
  }
  statement {
    sid       = "DynamoDbReadOnly"
    actions   = ["dynamodb:Describe*", "dynamodb:ListTagsOfResource"]
    resources = ["*"]
  }
  # IAM role names ARE predictable, scoped by name. Phase 4
  # (2026-09-21, "direct cutover"): widened from gateway-*-portal-*
  # only to also cover gateway-*-control-plane-*, now that the
  # backend's real ECS infra and role naming (modules/backend_service)
  # exist.
  statement {
    sid = "ManagePortalRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies", "iam:TagRole", "iam:UntagRole", "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/gateway-*-portal-*",
      "arn:aws:iam::${local.account_id}:role/gateway-*-control-plane-*",
    ]
  }
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
}

# Same shape as portal_deploy above -- identical resource scoping
# (gateway-dev-portal*, the same live ECS service), just under this
# repo's own OIDC trust so its own CI can deploy the image it builds.
data "aws_iam_policy_document" "control_plane_portal_deploy" {
  statement {
    sid = "PushToEcr"
    actions = [
      "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/gateway-dev-portal*"]
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
      values   = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:cluster/gateway-dev-portal*"]
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
    resources = ["arn:aws:iam::${local.account_id}:role/gateway-dev-portal*-execution"]
  }
}

module "github_oidc_control_plane" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.control_plane_repo

  roles = {
    plan = {
      role_name   = "gha-control-plane-infra-plan"
      policy_json = data.aws_iam_policy_document.control_plane_infra_plan.json
    }
    apply-dev = {
      role_name   = "gha-control-plane-infra-apply-dev"
      policy_json = data.aws_iam_policy_document.control_plane_infra_apply.json
    }
    dev = {
      role_name   = "gha-control-plane-portal-deploy-dev"
      policy_json = data.aws_iam_policy_document.control_plane_portal_deploy.json
    }
  }
}

# Same shape as control_plane_portal_deploy above, scoped to the
# backend's own real resource names instead. A separate module call,
# not a second key in the roles map above -- ci.yml's "Deploy backend
# to dev" and "Deploy portal to dev" jobs both use GitHub Environment
# "dev" (same repo, same environment name), but each needs its own
# distinct IAM role; one module's roles map can't have two entries
# under the same key. Same pattern bedrock-runtime-gateway's own
# github_oidc_app/github_oidc_infra split already uses for an
# analogous reason.
data "aws_iam_policy_document" "control_plane_backend_deploy" {
  statement {
    sid = "PushToEcr"
    actions = [
      "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/gateway-dev-control-plane*"]
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
      values   = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:cluster/gateway-dev-control-plane*"]
    }
  }
  statement {
    sid       = "RegisterTaskDefinition"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }
  statement {
    # Both the execution role AND the task role -- learned live: ECS
    # RegisterTaskDefinition needs to pass both when a task definition
    # specifies task_role_arn too, not just execution_role_arn (same
    # gap app_deploy's own PassEcsRoles statement already documents;
    # missed copying it here since portal_deploy -- what this was
    # adapted from -- has no task role of its own to pass).
    sid     = "PassBackendRoles"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/gateway-dev-control-plane*-execution",
      "arn:aws:iam::${local.account_id}:role/gateway-dev-control-plane*-task",
    ]
  }
}

module "github_oidc_control_plane_backend" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.control_plane_repo

  roles = {
    dev = {
      role_name   = "gha-control-plane-backend-deploy-dev"
      policy_json = data.aws_iam_policy_document.control_plane_backend_deploy.json
    }
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

  # Phase 3c (2026-09-21): this repo formally adopts the real, already-
  # live OIDC provider (created 2026-09-12 by the original, now-archived
  # bedrock-gateway-platform repo, referenced by every module call here
  # via a data source ever since -- confirmed live via `aws iam
  # get-open-id-connect-provider`, its real url/client_id_list/
  # thumbprint_list exactly match this module's hardcoded resource
  # block already). Picked this module call arbitrarily as the owner
  # -- any one of the seven would do, the module only supports
  # `create_oidc_provider = true` on exactly one caller at a time.
  # Imported, not created -- see migrate-oidc-provider-import.sh
  # (platform root).
  create_oidc_provider = true
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

# --- platform-edge-gateway repo (M12/plan.md Section 25 split): same
# plan/apply-dev/apply-prod shape as this repo's own roles above --
# it's Terraform doing plan+apply too, not a Docker build+deploy repo
# like app/portal/authz. Scoped to exactly what modules/api_gateway
# (that repo) touches: EC2 (its own VPC Link security group),
# ELB read-only (looks up the existing ALB/listener by name, doesn't
# manage it), and API Gateway v2 itself. --------------------------

data "aws_iam_policy_document" "api_gateway_plan" {
  statement {
    sid = "ReadOnly"
    actions = [
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "apigateway:GET",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
  statement {
    # Added for the module's access_log_settings CloudWatch log group +
    # resource policy (plan.md's live gap: the plan/apply-dev roles
    # predate that resource, so a plan against it 403s with
    # AccessDeniedException on logs:DescribeLogGroups otherwise).
    sid = "LogsReadOnly"
    actions = [
      "logs:Describe*",
      "logs:List*",
      "logs:GetLogGroupFields",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "TerraformStateS3"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::*tfstate*", "arn:aws:s3:::*tfstate*/*"]
  }
  # WAF-on-HTTP-API was tried and reverted (AWS WAFv2 doesn't support
  # API Gateway HTTP APIs -- see modules/api_gateway/main.tf's own
  # comment in platform-edge-gateway) but the plan role never got a
  # wafv2 grant at all (only apply-dev/apply-prod did, via WafBroad
  # below), so a plan can't even refresh the one Web ACL that got
  # created before the association failed -- 403 on wafv2:GetWebACL,
  # blocking the plan step that would otherwise destroy it cleanly.
  # Read-only, matching this document's own ReadOnly-statement style.
  statement {
    sid       = "WafReadOnly"
    actions   = ["wafv2:Get*", "wafv2:List*"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "api_gateway_apply" {
  statement {
    sid       = "Ec2Broad"
    actions   = ["ec2:*"]
    resources = ["*"]
  }
  statement {
    sid       = "ElbReadOnly"
    actions   = ["elasticloadbalancing:Describe*"]
    resources = ["*"]
  }
  statement {
    sid       = "ApiGatewayBroad"
    actions   = ["apigateway:*"]
    resources = ["*"]
  }
  statement {
    # Added for the module's access_log_settings CloudWatch log group +
    # resource policy (see api_gateway_plan's LogsReadOnly comment --
    # apply needs to create/update/delete both, not just read them).
    sid       = "LogsBroad"
    actions   = ["logs:*"]
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
  # Plan section 35.11 (P1 production hardening): the WAF Web ACL +
  # its association with the API Gateway stage -- never granted
  # before this. Web ACL ids don't exist until creation, same "*"
  # reasoning as every other broad grant here.
  statement {
    sid       = "WafBroad"
    actions   = ["wafv2:*"]
    resources = ["*"]
  }
}

module "github_oidc_api_gateway" {
  source = "../../modules/github_oidc"

  create_oidc_provider = false
  github_org           = var.github_org
  github_repo          = local.api_gateway_repo

  roles = {
    plan = {
      role_name   = "gha-api-gateway-plan"
      policy_json = data.aws_iam_policy_document.api_gateway_plan.json
    }
    apply-dev = {
      role_name   = "gha-api-gateway-apply-dev"
      policy_json = data.aws_iam_policy_document.api_gateway_apply.json
    }
    apply-prod = {
      role_name   = "gha-api-gateway-apply-prod"
      policy_json = data.aws_iam_policy_document.api_gateway_apply.json
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

  create_oidc_provider = false
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

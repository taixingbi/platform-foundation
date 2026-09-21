output "policy_publish_role_arn" {
  description = "Set as AWS_POLICY_PUBLISH_ROLE_ARN in platform-policy-definitions's GitHub Environment variables."
  value       = module.github_oidc_policies.role_arns["publish"]
}

output "portal_deploy_role_arns" {
  description = "Set as AWS_PORTAL_DEPLOY_ROLE_ARN_DEV / _PROD in bedrock-gateway-portal's GitHub Environment variables."
  value       = module.github_oidc_portal.role_arns
}

output "portal_deploy_role_arns" {
  description = "Set as AWS_PORTAL_DEPLOY_ROLE_ARN_DEV / _PROD in bedrock-gateway-portal's GitHub Environment variables."
  value       = module.github_oidc_portal.role_arns
}

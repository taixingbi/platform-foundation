output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "private_ca_arn" {
  description = "Every consumer hardcodes this as a literal string (see this file's own comment above) -- exposed here for visibility and to make updating those hardcoded copies easy if this CA is ever destroyed and recreated."
  value       = aws_acmpca_certificate_authority.internal.arn
}

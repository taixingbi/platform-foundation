# platform-foundation

Shared, account-level AWS infrastructure that every other repo in the
platform depends on but none of them should individually own:

- **`modules/network`** — VPC, public/private subnets (NAT per AZ),
  routing, S3/DynamoDB Gateway VPC endpoints. Moved here from
  `bedrock-runtime-gateway/infra` (Phase 3 of the platform
  restructuring, 2026-09-21) — see that repo's own history for the
  original design notes.
- **`modules/github_oidc`** — the account-wide GitHub OIDC provider
  singleton, plus a reusable "one role per CI job" pattern (plan/
  apply-dev/apply-prod, etc.) every repo's own `ci_identity/` root
  calls with `create_oidc_provider = false` to mint its own
  repo-scoped roles against the same provider.
- **`environments/dev`'s Private CA** — the internal ACM Private CA
  (`aws_acmpca_certificate_authority` + a self-signed root cert issued
  from it) every service's mTLS/internal-TLS chains up to.

Both the OIDC provider and the Private CA were moved here from
`bedrock-runtime-gateway/infra/environments/global` in the same Phase 3
restructuring as the network — real resources, real ARNs, migrated via
`terraform state mv`/`import`, never destroyed and recreated.

## Why this exists

Every repo that needs this VPC's `vpc_id`/subnet ids looks them up by
NAME via a data source (e.g. `data "aws_lb" "gateway" { name =
"gateway-dev-alb" }` → `.vpc_id`), never via `terraform_remote_state`
or a module reference — the same loose-coupling convention this whole
platform already uses everywhere. Centralizing VPC ownership here
means:

- Nobody's ECS/ALB/service repo can accidentally destroy or drift the
  network everything else lives inside.
- The one genuinely account-wide piece of infrastructure has one
  owner, reviewable in one Terraform diff.

The OIDC provider is the identity root every repo's CI authenticates
through, so it lives here permanently rather than migrating alongside
each repo's own roles (see "Terraform-ownership migration" below) — a
mistake against it risks every repo's CI at once, not just one.

## Environments

- `dev` — real, live network (moved from `bedrock-runtime-gateway/infra`
  via a `terraform state mv`/`push`, not recreated — same real VPC,
  same real NAT gateways, zero resource ARNs changed) plus the real,
  live Private CA.
- `global` — the account-wide OIDC provider singleton, plus this
  repo's own CI roles (`gha-foundation-plan`/`gha-foundation-apply-dev`,
  from `module.github_oidc_foundation`). Plan-only/manual apply always
  — see "CI/CD" below for why.
- `prod` — config mirror only, never applied ("hold prod", same
  convention as every other repo in this platform). Its network was
  never actually built in `bedrock-runtime-gateway/infra` either.

## Terraform-ownership migration (2026-09-21)

Every other repo's own CI roles (app, infra/edge-gateway, authz,
control-plane, policy-definitions) used to be defined centrally here,
in `environments/global`. Each has since moved to its own `ci_identity/`
Terraform root in its own repo, migrated via `terraform import`/`state
mv` (never delete/recreate, so ARNs and each repo's GitHub Environment
variables never changed) — see each repo's own README for its specific
migration notes. Only two things stay here permanently:

- The OIDC provider singleton itself (`module.github_oidc_foundation`,
  `create_oidc_provider = true` — the only module call in the whole
  platform with this set to `true`). Its ownership moved here from
  `module.github_oidc_infra` via `terraform state mv` (not
  import/recreate) specifically because this module call was never
  going to migrate again afterward.
- This repo's own CI roles (`gha-foundation-plan`/`-apply-dev`),
  managed by that same module call.

`bedrock-gateway-portal`'s own roles (`gha-portal-deploy-dev/prod`)
were the one exception: removed outright (not migrated) on
2026-09-21, once `platform-control-plane`'s own portal was confirmed
already live and `bedrock-gateway-portal` was archived on GitHub.

## CI/CD

`dev` auto-applies on push to `main`, same convention as every other
repo — scoped to only `environments/dev`'s own resources (network +
Private CA), via a role with no `iam:*`/OIDC-provider permissions at
all. `global` and `prod` stay plan-only/manual hand-off: `global` owns
the OIDC provider itself and (historically) every other repo's own
CI roles, so a bad apply there risks every other repo's CI, not just
this one — no equivalent risk tier exists in any sibling repo's own
"prod". `prod` is never applied at all, per this account's standing
"hold prod" convention.

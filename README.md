# platform-foundation

Shared, account-level AWS infrastructure that every other repo in the
platform depends on but none of them should individually own:

- **`modules/network`** — VPC, public/private subnets (NAT per AZ),
  routing, S3/DynamoDB Gateway VPC endpoints. Moved here from
  `bedrock-runtime-gateway/infra` (Phase 3 of the platform
  restructuring, 2026-09-21) — see that repo's own history for the
  original design notes.

Planned, not yet moved here: the account-wide GitHub OIDC provider +
every repo's OIDC roles, and the shared internal Private CA
(currently both still in `bedrock-runtime-gateway/infra/environments/
global`) — deliberately split into a separate, later step: unlike the
VPC, the OIDC provider is the identity root every repo's CI
authenticates through, so a mistake moving it breaks every repo's CI
simultaneously, not just this platform's live traffic.

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

## Environments

- `dev` — real, live (moved from bedrock-runtime-gateway/infra via a
  `terraform state mv`/`push`, not recreated — same real VPC, same
  real NAT gateways, zero resource ARNs changed).
- `prod` — config mirror only, never applied ("hold prod", same
  convention as every other repo in this platform). Its network was
  never actually built in bedrock-runtime-gateway/infra either.

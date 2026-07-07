# Architecture & design decisions

This doc collects the "why" behind non-obvious choices, phase by phase, so
the reasoning survives even after the code looks obvious in hindsight. See
the [interview talking points](../README.md) framing in the top-level spec
for the questions these decisions are meant to answer.

## Phase 0 — Foundations & guardrails

### Why Terraform Registry's `terraform-aws-modules/vpc` instead of hand-rolled resources

VPC route table / NAT / IGW wiring is easy to get subtly wrong (e.g. a
private subnet route pointing at the wrong NAT, or missing the
`kubernetes.io/role/elb` discovery tags the AWS Load Balancer Controller
needs). `terraform-aws-modules/vpc` is the de facto standard, version-pinned
(`~> 5.19`), and its correctness is already exercised by a huge number of
production users — boring and well-documented beats bespoke here.

### Why a separate `bootstrap/` config with local state instead of one root module

Terraform's S3 backend needs an S3 bucket and DynamoDB table to exist
*before* it can use them — a chicken-and-egg problem. `bootstrap/` is the
one config allowed to use local state; everything else (`envs/lab`) uses the
S3 backend bootstrap creates. Bootstrap's local `terraform.tfstate` is
gitignored, not committed — if it's ever lost, the bucket/table can be
re-imported (`terraform import`) rather than recreated, since they're
`prevent_destroy`d anyway.

### Budget thresholds

This project runs on a **student/burner AWS account with $140 total
credit** for the entire multi-week build (confirmed via
`aws freetier get-account-plan-state`), not a company card. The spec's
suggested $10/$25 alert pair was tightened to **$10 / $25 / $50** — three
SNS email alerts on a $50 monthly budget — so a forgotten `terraform
destroy` gets caught with roughly $90 of runway left for the rest of the
build, instead of risking a slow bleed through most of the total credit
before anyone notices. Whether this project can be built at all inside that
constraint is itself a big part of the FinOps story: the whole point of
spot-backed, ephemeral, apply→destroy infrastructure is that a $140 lab
budget can plausibly cover EKS + Karpenter + FIS experiments if nothing is
ever left running idle.

### Why AWS-managed KMS keys instead of skipping encryption-at-rest checks

Checkov's default ruleset wants customer-managed CMKs for S3/SNS/ECR
encryption. A CMK costs ~$1/month *per key* regardless of usage — real
money against a $140 budget for a property (defense against an AWS-internal
compromise of the AWS-managed key) that's out of scope for a lab threat
model. Using the AWS-managed key aliases (`alias/aws/s3`, `alias/aws/sns`,
ECR's default KMS type) satisfies the same encryption-at-rest checks for
free. See `.checkov.yaml` for the small number of checks skipped outright
(cross-region replication, access-logging buckets, DynamoDB CMK) with a
one-line reason each — the point of policy-as-code is to make these
tradeoffs explicit and reviewable, not to blindly satisfy every rule
regardless of cost/benefit.

### Why GitHub OIDC instead of stored AWS access keys, even for `terraform plan`

Long-lived AWS keys in a GitHub Actions secret are a standing credential
that outlives any single workflow run and can leak via logs, forks, or a
compromised action. OIDC federation (`aws_iam_openid_connect_provider` +
`sts:AssumeRoleWithWebIdentity`) issues a short-lived, per-run credential
scoped by the GitHub-issued JWT's `sub` claim to exactly
`repo:Heramb04/prlab:*` — no other repo, even one in the same account, can
assume this role. The plan role is deliberately **plan-only**: it holds
`ReadOnlyAccess` plus narrow read/write on just the state bucket object and
lock table (Terraform still needs to take/release the DynamoDB lock around
a read). CI never runs `apply`; that stays a manual, deliberate action per
the apply→build→destroy discipline.

### Why the GitHub OIDC thumbprint is fetched via `data.tls_certificate` instead of hardcoded

GitHub rotates the TLS certificate behind `token.actions.githubusercontent.com`
periodically, which has broken hardcoded-thumbprint OIDC setups across the
industry before. Fetching it live via a `tls_certificate` data source at
plan/apply time means this config self-heals across that rotation instead
of silently failing until someone remembers to update a hex string.

### Why a single NAT gateway instead of one per AZ

A NAT gateway costs ~$32/month plus per-GB data processing just sitting
idle, multiplied by AZ count. This removes AZ-level fault isolation for
private-subnet egress traffic — if the NAT's AZ has an issue, all preview
pods lose internet egress until it recovers — but for a lab where every
session is apply→build→destroy anyway, paying 2-3x for that isolation isn't
worth it against a $140 total budget.

### Why no RDS

Preview environments are disposable and short-lived (default 48h TTL); they
don't need managed backups, multi-AZ failover, or point-in-time recovery —
properties RDS charges for. Postgres runs in-cluster on a small PVC per
preview namespace instead, seeded fresh from `init.sql` each time. This is a
deliberate tradeoff to say out loud in an interview, not an oversight.

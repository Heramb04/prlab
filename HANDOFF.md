# Handoff notes

Read this first when resuming work on prlab, whether you're a fresh Claude
session or the human coming back after a break. It's a snapshot, not a
source of truth — anything with a timestamp below may be stale by the time
you read it; re-verify live state before acting on it (especially AWS
resource status and credit balance).

**Last updated:** 2026-07-08T05:59Z, end of Phase 2.

## Snapshot at last update

- EKS cluster `prlab-lab` (us-east-1): **ACTIVE**, 2× `t3.small` nodes
  running. **This is costing money right now if you're reading this
  later** — see "Cost discipline" below before doing anything else.
- AWS Free Plan credits remaining: **$159.12** (yes, higher than the $140
  seen at project start — the plan tops up in tranches or billing lags;
  don't be alarmed either way, just re-check with the command below).
- ArgoCD installed and healthy, ApplicationSet applied, ready to accept
  PRs. No open PRs on `prlab-demo-app` right now, so no `Application`
  objects currently exist (that's expected, not broken).
- Both repos pushed and in sync with what's actually deployed:
  [Heramb04/prlab](https://github.com/Heramb04/prlab) (infra),
  [Heramb04/prlab-demo-app](https://github.com/Heramb04/prlab-demo-app) (app).

Re-verify with:

```sh
source ~/.bashrc && export AWS_PROFILE=prlab
aws eks describe-cluster --name prlab-lab --region us-east-1 --query 'cluster.status'
aws freetier get-account-plan-state --region us-east-1 --query 'accountPlanRemainingCredits'
kubectl get pods -n argocd
kubectl get applications -n argocd
```

## What's done

- **Phase 0** — Terraform bootstrap (S3+DynamoDB state backend), AWS
  Budgets ($10/$25/$50 SNS alerts, confirmed), VPC/network, ECR, GitHub
  OIDC (plan-only role), CI (fmt/validate/tflint/checkov + PR plan
  comment). Everything passes fmt/tflint/checkov cleanly.
- **Phase 1** — EKS cluster, ALB controller, metrics-server, `gp3`
  StorageClass, demo FastAPI+Postgres app, `charts/preview-app` Helm
  chart. Manually verified reachable.
- **Phase 2** — ArgoCD + ApplicationSet Pull Request generator +
  Notifications. Verified live, twice, end-to-end: PR open → CI
  build/push → Application synced (~90s) → preview reachable → PR comment
  posted (~4m28s, inside the 5-min SLO) → PR closed → Application,
  namespace, workloads, and PVC all pruned automatically.
- **Not started:** Phase 3 (Kyverno policy + TTL reaper), Phase 4
  (Karpenter spot + FIS interruption testing), Phase 5 (observability,
  SLOs, polish).

Full detail and the reasoning behind every non-obvious choice:
[README.md](README.md) and [docs/architecture.md](docs/architecture.md).
The architecture doc in particular has a phase-by-phase "why" section that
explains several real bugs hit and fixed during live testing — worth
reading before assuming something works as documented elsewhere.

## Environment / access notes (this machine specifically)

- Portable toolchain (terraform, aws cli, kubectl, helm, tflint) lives on
  the HDD at `/run/media/bazzite/HERAMB/Claude/tools/bin`, already on
  `PATH` via `~/.bashrc`. `checkov` is at `/var/data/python/bin` (not on
  default PATH — add manually: `export PATH="/var/data/python/bin:$PATH"`).
- Every Bash tool invocation is a **fresh non-login shell** that does not
  auto-source `~/.bashrc`. Prefix commands with `source ~/.bashrc` (or
  they'll report `command not found` for terraform/aws/kubectl/helm even
  though they're installed).
- AWS credentials: profile `prlab` in `~/.aws/credentials` (already
  configured, not committed anywhere). Always `export AWS_PROFILE=prlab`
  — do not use the default profile, which is a different, unrelated AWS
  account.
- GitHub: `gh` CLI already authenticated as `Heramb04` with `repo`,
  `workflow`, `read:org`, `gist` scopes. ArgoCD's GitHub token is sourced
  live from `gh auth token` at `terraform apply` time via
  `TF_VAR_github_token` — it is not stored in any file, secret, or state
  in plaintext beyond the Kubernetes Secret it ends up in.
- Budget alert email is a GitHub Actions secret (`BUDGET_ALERT_EMAIL` on
  the infra repo) and a local-only `terraform.tfvars` value — intentionally
  not in this file or git history (repo is public).

## Known gotchas (learned the hard way — don't rediscover these)

- **This AWS account is on the Free Plan**, which hard-blocks On-Demand
  launches of any EC2 instance type outside the free-tier-eligible list.
  `t3.medium` fails silently (ASG retries forever, EKS doesn't surface the
  error quickly). Use `t3.small` or another free-tier type. If you add
  Karpenter capacity in Phase 4, check this constraint applies there too.
- **sslip.io needs dashes, not dots**, around an IP once there's a
  subdomain prefix: `pr-0.54-235-16-247.sslip.io` works,
  `pr-0.54.235.16.247.sslip.io` resolves to garbage.
- **Helm ownership conflicts cut both ways.** A plain `helm install
  --create-namespace` conflicts with a chart that also declares its own
  `Namespace` resource ("already exists"). But ArgoCD-managed syncs need
  that same `Namespace` resource declared in the chart, or the namespace
  (and anything still in it, like PVCs) won't get pruned when the PR
  closes and the Application is deleted. `charts/preview-app` currently
  has the Namespace template in *because* it's ArgoCD-managed now — if you
  ever go back to testing with plain `helm install` again, you'll hit the
  Phase 1 conflict again.
- **Go templates can't dot-access a hyphenated map key** —
  `{{.app.labels.pr-number}}` fails to parse. Either use
  `{{index .app.labels "pr-number"}}` or, simpler, derive the value from
  something without hyphens (we use `{{trimPrefix "pr-" .app.metadata.name}}`).
- **StatefulSet PVCs need an explicit `persistentVolumeClaimRetentionPolicy`**
  (`whenDeleted: Delete`) or they silently outlive the StatefulSet and leak
  EBS volumes forever.
- **ArgoCD's `.app.status.summary.externalURLs` auto-populates from an
  Ingress's `status.loadBalancer.ingress[].hostname`** with no extra
  annotation needed — confirmed live. Used instead of trying to template a
  sslip.io hostname per-PR (impossible without a second reconciliation
  step, since the ALB IP isn't known until after the Ingress syncs).

## Cost discipline

- EKS control plane: ~$0.10/hr. 2× `t3.small` nodes: free-tier-eligible,
  effectively ~$0. NAT gateway + ALB(s): a few cents/hr each. Rough total
  while everything's up: **$2-3/day**.
- Destroy when done for the session:
  ```sh
  cd terraform/envs/lab
  export AWS_PROFILE=prlab
  terraform destroy
  ```
- Rebuilding from scratch next time: ~12-15 minutes (control plane ~7-8
  min, node group ~3-4 min, ALB controller/metrics-server ~2 min) — no
  longer has the `t3.medium` stuck-node-group problem since that's fixed
  in code. Not instant (EKS has no pause/hibernate), but fully scripted.
- Bootstrap state bucket/DynamoDB lock table are `prevent_destroy`d and
  meant to survive between sessions (they cost nothing idle) — `terraform
  destroy` in `envs/lab` won't touch them.

## Suggested next step

Phase 3: Kyverno policy-as-code (disallow root containers, require
resource limits, restrict image registry to project ECR) + a Python TTL
reaper CronJob (warn at TTL−6h, force-close past 48h — defense in depth
for the Phase 2 auto-prune, since we've now personally seen two ways
automatic cleanup can silently leave resources behind if not built
carefully).

# Handoff notes

Read this first when resuming work on prlab, whether you're a fresh Claude
session or the human coming back after a break. It's a snapshot, not a
source of truth — anything with a timestamp below may be stale by the time
you read it; re-verify live state before acting on it (especially AWS
resource status and credit balance).

**Last updated:** 2026-07-08T11:00Z, end of Phase 3.

## Snapshot at last update

- EKS cluster `prlab-lab` (us-east-1): **ACTIVE**, 2× `t3.small` nodes
  running (fresh ones, prefix-delegation mode, maxPods=110). **This is
  costing money right now if you're reading this later** — see "Cost
  discipline" below before doing anything else.
- AWS Free Plan credits: **$159.12 at last check** (higher than the $140
  seen at project start — the plan tops up in tranches or billing lags;
  re-check with the command below).
- ArgoCD + Kyverno installed and healthy. ApplicationSet, 4 ClusterPolicies
  (all Ready, Enforce), and the TTL reaper CronJob (every 15 min, argocd
  namespace) all applied. No open PRs right now, so no Application objects
  or preview namespaces exist (expected, not broken).
- Both repos pushed and in sync with what's actually deployed:
  [Heramb04/prlab](https://github.com/Heramb04/prlab) (infra),
  [Heramb04/prlab-demo-app](https://github.com/Heramb04/prlab-demo-app) (app).

Re-verify with:

```sh
source ~/.bashrc && export AWS_PROFILE=prlab
aws eks describe-cluster --name prlab-lab --region us-east-1 --query 'cluster.status'
aws freetier get-account-plan-state --region us-east-1 --query 'accountPlanRemainingCredits'
kubectl get pods -n argocd; kubectl get pods -n kyverno
kubectl get applications -n argocd; kubectl get clusterpolicies
kubectl get cronjob -n argocd
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
- **Phase 3** — Kyverno 3.7.2 + 4 ClusterPolicies (disallow-root,
  require-limits, restrict-registries, quota/limitrange generation), all
  verified by live denials (docs/evidence/kyverno-denials.md); chart and
  demo-app hardened to non-root and passing end-to-end; TTL reaper
  (unit-tested Python CronJob) verified live: warned PR #3 at
  TTL−warn-window, closed it past TTL, ArgoCD pruned everything; orphan
  path verified against a synthetic namespace. Also: VPC CNI prefix
  delegation + maxPods=110 (was 11/node — the whole fleet had 2 free pod
  slots before this).
- **Not started:** Phase 4 (Karpenter spot + FIS interruption testing),
  Phase 5 (observability, SLOs, polish).

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
- **Prefix delegation only applies to nodes that boot after it's enabled.**
  Enabling ENABLE_PREFIX_DELEGATION on the vpc-cni addon does nothing for
  running nodes whose ENI slots are already full of individual secondary
  IPs — pods beyond the old ~11/node limit hang in ContainerCreating with
  "failed to assign an IP address". Fix: drain + terminate nodes one at a
  time and let the ASG replace them (verified: replacements come up with
  /28 prefixes attached). Also: the eks module needs `ami_type` set
  explicitly on the node group or `cloudinit_pre_nodeadm` (the maxPods
  override) is silently dropped.
- **The vpc-cni addon's `before_compute` move races on existing clusters**
  (new addon create can 409 before the old one finishes deleting). The
  re-apply converges. And a terraform apply that exits 1 may still have
  done most of its work — check what actually happened before re-running.
- **`terraform apply` needs `TF_VAR_github_token=$(gh auth token)`** since
  Phase 2, and the reaper CronJob reads the same token from the
  argocd-notifications-secret. If ArgoCD PR polling or reaper GitHub calls
  ever 401, the gh session token was probably rotated/revoked — re-apply
  with a fresh token.
- **The reaper's TTL/warn/grace are env vars on the CronJob** — for a live
  test, create a one-off Job from the CronJob with short overrides (see
  the make_reaper_test_job.py pattern in session scratchpad / git history)
  rather than editing the CronJob itself.

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

Phase 4: Karpenter via Terraform (spot NodePool with on-demand fallback,
tainted for previews + toleration in the chart), AWS FIS spot-interruption
experiment, spot-savings Prometheus exporter. **Check first whether this
Free Plan account can launch spot instances at all** (it hard-blocks
non-free-tier On-Demand types; spot may or may not share that
restriction — test with a tiny spot request before building everything on
the assumption). Nodes must also tolerate Karpenter's requirements; the
existing system node group stays as-is for platform pods.

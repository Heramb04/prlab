# prlab-infra

Platform repo for **prlab** — every pull request on [`prlab-demo-app`](https://github.com/Heramb04/prlab-demo-app)
gets its own fully isolated, live preview environment on AWS EKS, provisioned
via GitOps (ArgoCD), running on spot instances, guarded by policy-as-code
(Kyverno), and operated against a published SLO.

Environments are created on PR open, destroyed on PR close, and a TTL reaper
kills anything forgotten. Zero manual steps after Phase 2, near-zero idle
cost.

See [docs/architecture.md](docs/architecture.md) for the full design and the
reasoning behind each non-obvious choice, and [docs/slo.md](docs/slo.md) for
the platform's SLOs once Phase 5 lands.

## Status

Building phase by phase. Currently: **Phase 2 — GitOps previews with ArgoCD**, done.

- [x] Phase 0 — Foundations & guardrails
- [x] Phase 1 — Cluster + one manual preview
- [x] Phase 2 — GitOps previews with ArgoCD
- [ ] Phase 3 — Policy + TTL safety net
- [ ] Phase 4 — Spot + interruption resilience
- [ ] Phase 5 — Observability, SLOs & polish

## Repo layout

```
terraform/
├── bootstrap/         # one-time: S3 state bucket + DynamoDB lock table (local state)
├── modules/
│   ├── budgets/       # AWS Budget + SNS email alerts
│   ├── network/       # VPC, subnets, single NAT gateway
│   ├── ecr/           # ECR repo + lifecycle policy
│   ├── github-oidc/   # GitHub OIDC provider + plan/ECR-push IAM roles
│   ├── eks/           # EKS cluster, node group, ALB controller, metrics-server
│   └── argocd/        # ArgoCD install (Terraform helm_release)
└── envs/lab/          # the one environment this project runs (S3 backend)
charts/preview-app/    # Helm chart: demo app + Postgres (StatefulSet) + ALB Ingress
argocd/
├── applicationset-previews.yaml   # PR generator - the heart of the platform
└── notifications.yaml             # PR comment on sync-healthy
.github/workflows/
└── terraform.yml      # fmt, validate, tflint, checkov, plan-as-PR-comment
docs/
└── architecture.md    # design decisions and why
```

## How previews work (Phase 2 — fully automatic)

Opening a PR on `prlab-demo-app` **is** the provisioning action:

1. `ci.yml` builds and pushes an image tagged `pr-<number>-<full-sha>` to
   ECR via GitHub OIDC.
2. ArgoCD's `prlab-previews` ApplicationSet polls `prlab-demo-app` every
   60s via its Pull Request generator, and creates/updates an
   `Application` named `pr-<number>` for every open PR, synced from this
   repo's `charts/preview-app` on `main`.
3. Once synced and healthy, ArgoCD Notifications posts
   `prlab preview ready: http://<alb-hostname>/` as a PR comment
   (typically within ~4-5 minutes of PR open).
4. Closing the PR removes it from the generator's result set; ArgoCD
   prunes the `Application` and, because the namespace is itself a
   chart-managed resource, the whole namespace (and everything still in
   it) goes with it. No teardown pipeline.

One-time bootstrap after `terraform apply` (ArgoCD itself is
Terraform-managed, but its ApplicationSet/Notifications config are applied
via `kubectl` — see [docs/architecture.md](docs/architecture.md) for why
CRD-heavy config like this stays outside Terraform's kubernetes_manifest):

```sh
aws eks update-kubeconfig --name prlab-lab --region us-east-1
kubectl apply -f argocd/applicationset-previews.yaml
kubectl apply -f argocd/notifications.yaml
```

The GitHub token used by both the PR generator and Notifications is passed
to Terraform via `TF_VAR_github_token` at apply time (e.g.
`export TF_VAR_github_token=$(gh auth token)`) — never committed, never
printed.

ArgoCD's own UI (optional, for visual inspection):

```sh
kubectl port-forward -n argocd svc/argocd-server 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

## Cost discipline (non-negotiable)

- **EKS control plane costs ~$73/month if left running — never leave it up.**
  Every session: `apply → build → destroy`.
- AWS Budget alerts at $10 / $25 / $50 (this project runs on a **$140 total
  credit** student/burner account — see [docs/architecture.md](docs/architecture.md#budget-thresholds)).
- Single NAT gateway, not one per AZ.
- Spot for all preview capacity once Karpenter lands (Phase 4).
- No RDS — Postgres runs in-cluster on small PVCs.

## Getting started (bootstrap, once per AWS account)

```sh
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit: your own unique bucket name
terraform init
terraform apply
```

Then the lab environment:

```sh
cd terraform/envs/lab
cp terraform.tfvars.example terraform.tfvars   # edit: your email, your GitHub repo
export TF_VAR_github_token=$(gh auth token)    # for ArgoCD's PR generator + Notifications
terraform init
terraform apply
```

After apply, check email for an SNS subscription-confirmation link and
confirm it — budget alerts won't fire otherwise.

## Tearing down

Close any open PRs first so ArgoCD prunes their previews cleanly (or just
let `terraform destroy` tear down the whole cluster under them — either
works, closing PRs first is just tidier). The ApplicationSet/Notifications
config applied via `kubectl` isn't Terraform-managed, but it lives inside
the cluster and disappears with it — nothing extra to clean up there.

```sh
cd terraform/envs/lab
terraform destroy
```

The bootstrap state bucket/lock table are `prevent_destroy`d and normally
left in place between sessions (they cost nothing idle).

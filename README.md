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

Building phase by phase. Currently: **Phase 1 — Cluster + one manual preview**, done.

- [x] Phase 0 — Foundations & guardrails
- [x] Phase 1 — Cluster + one manual preview
- [ ] Phase 2 — GitOps previews with ArgoCD
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
│   └── eks/           # EKS cluster, node group, ALB controller, metrics-server
└── envs/lab/          # the one environment this project runs (S3 backend)
charts/preview-app/    # Helm chart: demo app + Postgres (StatefulSet) + ALB Ingress
.github/workflows/
└── terraform.yml      # fmt, validate, tflint, checkov, plan-as-PR-comment
docs/
└── architecture.md    # design decisions and why
```

## Manual preview (Phase 1)

Until Phase 2 wires up ArgoCD, previews are installed by hand:

```sh
aws eks update-kubeconfig --name prlab-lab --region us-east-1

helm install pr-0 charts/preview-app -n pr-0 --create-namespace \
  --set image.repository=<ecr_repository_url output> \
  --set image.tag=<tag from prlab-demo-app's CI run> \
  --set gitSha=<short sha> \
  --set pr.number=0

kubectl label namespace pr-0 preview=true pr-number=0 --overwrite
```

Get the ALB's hostname from `kubectl get ingress -n pr-0`, resolve its IP,
then optionally re-run `helm upgrade` with
`--set ingress.host=pr-0.<ip-with-dashes>.sslip.io` (dashes, not dots,
around the IP — see [docs/architecture.md](docs/architecture.md)).

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
terraform init
terraform apply
```

After apply, check email for an SNS subscription-confirmation link and
confirm it — budget alerts won't fire otherwise.

## Tearing down

Manual `helm install`s aren't Terraform-managed, so uninstall those first:

```sh
helm uninstall pr-0 -n pr-0
kubectl delete namespace pr-0
```

Then:

```sh
cd terraform/envs/lab
terraform destroy
```

The bootstrap state bucket/lock table are `prevent_destroy`d and normally
left in place between sessions (they cost nothing idle).

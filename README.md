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
the platform's SLOs and error-budget policy.

**Resuming work?** Read [HANDOFF.md](HANDOFF.md) first — current live AWS
state, what's actually verified working, environment/access notes specific
to the dev machine, and gotchas already hit and fixed so you don't
rediscover them.

## How it works

```
        GitHub PR opened on prlab-demo-app
                    │
                    ▼
     GitHub Actions (OIDC → IAM, no stored keys)
        builds image → pushes to ECR
        tag: pr-<number>-<full-sha>          CI never touches the cluster.
                    │
                    ▼
     ArgoCD ApplicationSet — Pull Request generator (60s poll)
        one Application per open PR, synced from charts/preview-app
                    │
        ┌───────────┴────────────────────────────────┐
        ▼                                            ▼
   namespace pr-<n>  (preview=true)          Kyverno admission policies
   ├─ app Deployment (non-root)              ├─ disallow root containers
   ├─ Postgres StatefulSet + PVC             ├─ require requests/limits
   ├─ ALB Ingress → public URL               ├─ registry allowlist
   └─ ResourceQuota + LimitRange  ◄──────────┴─ (generated per namespace)
        │
        ▼                                    Karpenter NodePool "preview"
   pods land on tainted SPOT t3.smalls  ◄──  spot-first, on-demand fallback,
        │                                    SQS interruption handling,
        ▼                                    consolidation back to spot
   ArgoCD Notifications: posts
   "preview ready: <url>" as a PR comment   (~1-5 min after PR open;
        │                                    SLO: 99% within 5 min)
        ▼
   PR closed/merged → generator drops the Application →
   ArgoCD prunes namespace, workloads, PVC. Nothing to tear down.

   Safety nets:  TTL reaper CronJob (warn at TTL−6h, close PR past 48h,
                 delete orphans whose prune failed)
   Observability: kube-prometheus-stack + Grafana dashboard
                 (SLO success rate, error budget, spot $ saved,
                 interruptions handled, node mix)
```

## Status

All five phases complete and verified live.

- [x] Phase 0 — Foundations & guardrails
- [x] Phase 1 — Cluster + one manual preview
- [x] Phase 2 — GitOps previews with ArgoCD
- [x] Phase 3 — Policy + TTL safety net
- [x] Phase 4 — Spot + interruption resilience
- [x] Phase 5 — Observability, SLOs & polish

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
│   ├── argocd/        # ArgoCD install (Terraform helm_release)
│   ├── kyverno/       # Kyverno install (policy engine)
│   ├── karpenter/     # Karpenter controller + IRSA + SQS interruption queue
│   ├── spot-exporter/ # IRSA for the spot-savings exporter
│   └── fis/           # FIS spot-interruption template (needs an account
│                      # with FIS; not instantiated on this Free Plan one)
└── envs/lab/          # the one environment this project runs (S3 backend)
charts/preview-app/    # Helm chart: demo app + Postgres (StatefulSet) + ALB Ingress
argocd/
├── applicationset-previews.yaml   # PR generator - the heart of the platform
└── notifications.yaml             # PR comment on sync-healthy
karpenter/             # preview NodePool + EC2NodeClass (spot-first, tainted)
policies/              # Kyverno ClusterPolicies: disallow-root, require-limits,
                       # restrict-registries, per-namespace quota/limits generation
reaper/                # TTL reaper: Python CronJob, unit-tested; warns at TTL-6h
                       # then closes the PR (teardown rides the normal prune path)
exporters/             # spot-savings Prometheus exporter ($ saved vs on-demand)
.github/workflows/
├── terraform.yml      # fmt, validate, tflint, checkov, plan-as-PR-comment
├── reaper.yml         # reaper: pytest on PR, build+push image on main
└── exporter.yml       # exporter: build+push image on main
docs/
├── architecture.md    # design decisions and why
└── evidence/          # captured live: policy denials, interruption recovery
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

Guardrails on every preview namespace (Phase 3):

- **Kyverno policies** (`policies/`): containers must not run as root,
  must declare requests/limits, images only from the project ECR (plus the
  ECR Public mirror for Postgres). Violations are denied at admission with
  actionable messages — captured live in
  [docs/evidence/kyverno-denials.md](docs/evidence/kyverno-denials.md).
- **ResourceQuota + LimitRange** generated automatically in every
  `preview=true` namespace by a Kyverno generate policy.
- **TTL reaper** (`reaper/`): CronJob every 15 min. Warns on the PR at
  TTL−6h, closes the PR past TTL (48h) so teardown rides the normal ArgoCD
  prune path; directly deletes only *orphans* (closed PRs whose prune
  failed). Unit-tested; images built by CI on pushes to `main`.

One-time bootstrap after `terraform apply` (ArgoCD itself is
Terraform-managed, but CRD-heavy config — ApplicationSet, Notifications,
Kyverno policies, the reaper CronJob — is applied via `kubectl`; see
[docs/architecture.md](docs/architecture.md) for why):

```sh
aws eks update-kubeconfig --name prlab-lab --region us-east-1
kubectl apply -f argocd/applicationset-previews.yaml
kubectl apply -f argocd/notifications.yaml
kubectl apply -f policies/
kubectl apply -f reaper/cronjob.yaml
kubectl apply -f karpenter/nodepool-preview.yaml
kubectl apply -f exporters/deployment.yaml
kubectl apply -f monitoring/servicemonitors.yaml
kubectl create configmap prlab-dashboard -n monitoring \
  --from-file=preview-platform.json=dashboards/preview-platform.json
kubectl label configmap prlab-dashboard -n monitoring grafana_dashboard=1
```

Preview pods run on Karpenter-provisioned **spot** t3.smalls (tainted, so
platform pods stay on the managed node group), with on-demand fallback and
automatic consolidation back to spot — interruption handling verified live
with a synthetic spot-interruption event; see
[docs/evidence/spot-interruption-recovery.md](docs/evidence/spot-interruption-recovery.md)
(75s from warning to fully recovered preview).

The GitHub token used by both the PR generator and Notifications is passed
to Terraform via `TF_VAR_github_token` at apply time (e.g.
`export TF_VAR_github_token=$(gh auth token)`) — never committed, never
printed.

ArgoCD's own UI (optional, for visual inspection):

```sh
kubectl port-forward -n argocd svc/argocd-server 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

Grafana (dashboard: **prlab — Preview Platform**; login `admin` /
`prlab-grafana`):

```sh
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# http://localhost:3000/d/prlab-preview-platform
```

## Demo script (2-3 minutes, screen-record this)

1. Show the Grafana dashboard: 0 active previews, node mix empty.
2. Open a PR on `prlab-demo-app` (any trivial change).
3. Narrate while it provisions (~1-5 min): CI builds the image, ArgoCD's
   PR generator picks it up, Karpenter launches a spot node.
4. The bot comments `prlab preview ready: <url>` — open the URL: the
   health page shows the PR number, git SHA, and **Node type: spot**.
5. Back to Grafana: active previews = 1, spot node up, $ saved ticking,
   the PR's ready-time bar under the 300s line, SLO at 100%.
6. Close the PR. Watch the namespace disappear (`kubectl get ns`) and the
   spot node get consolidated away. Dashboard back to 0 — and $0.

## Cost discipline (non-negotiable)

- **EKS control plane costs ~$73/month if left running — never leave it up.**
  Every session: `apply → build → destroy`.
- AWS Budget alerts at $10 / $25 / $50 (this project runs on a **$140 total
  credit** student/burner account — see [docs/architecture.md](docs/architecture.md#budget-thresholds)).
- Single NAT gateway, not one per AZ.
- All preview capacity is Karpenter-provisioned spot (~60% cheaper), exists
  only while PRs are open, and consolidates away on close.
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

# prlab — PR Preview Environments Platform

An internal developer platform on AWS: **every pull request gets its own
isolated, live environment** — provisioned by GitOps, running on spot
instances, guarded by policy-as-code, and operated against a published SLO.

Opening a PR on the [demo application repo](https://github.com/Heramb04/prlab-demo-app)
is the only action a developer takes. The platform builds the image, stands
up a full environment (app + database + load balancer), and comments the
live URL back on the PR — typically within 1–5 minutes, against a
**99% / 5-minute readiness SLO**. Closing the PR removes everything. There
is no teardown pipeline, no ticket, no kubectl.

> **Why this exists:** most teams share one staging environment and queue
> for it. Preview environments are the industry fix (Vercel and Netlify do
> it for frontends; Shipyard and Okteto sell it for backends). This project
> builds that capability from scratch on AWS, including the parts the
> managed products hide: cost engineering, policy enforcement, interruption
> resilience, and SLO-driven operation.

## Architecture

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
   pods land on tainted SPOT nodes      ◄──  spot-first, on-demand fallback,
        │                                    SQS interruption handling,
        ▼                                    consolidation back to spot
   ArgoCD Notifications: posts
   "preview ready: <url>" as a PR comment
        │
        ▼
   PR closed/merged → generator drops the Application →
   ArgoCD prunes namespace, workloads, PVC. Nothing to tear down.

   Safety net:    TTL reaper CronJob (warns on the PR near TTL, closes
                  abandoned PRs, deletes orphans whose prune failed)
   Observability: kube-prometheus-stack + Grafana (SLO success rate,
                  error budget, spot savings, interruptions, node mix)
```

## Highlights

- **GitOps, pull-based.** CI only builds artifacts; ArgoCD reconciles the
  cluster from git. Cluster credentials never leave the cluster, drift
  self-heals, and *deletion is declarative* — closing a PR is the teardown.
- **Spot-backed FinOps.** All preview capacity is Karpenter-provisioned
  spot (~60% below on-demand), exists only while PRs are open, and
  consolidates away on close. A custom Prometheus exporter tracks realized
  savings.
- **Interruption resilience, tested — not assumed.** A spot interruption
  was injected against a live preview node: Karpenter tainted the node in
  2s, launched a replacement in 6s, and the environment fully recovered
  (EBS re-attached, database serving writes) in **75 seconds** — then
  automatically consolidated back to spot. Timeline:
  [docs/evidence/spot-interruption-recovery.md](docs/evidence/spot-interruption-recovery.md).
- **Policy-as-code with receipts.** Kyverno denies root containers,
  missing resource limits, and images from unapproved registries — each
  policy verified by a deliberately violating deployment, denials captured
  in [docs/evidence/kyverno-denials.md](docs/evidence/kyverno-denials.md).
  Every preview namespace gets a generated ResourceQuota and LimitRange.
- **Defense in depth for cleanup.** ArgoCD prunes on PR close; a
  unit-tested Python TTL reaper handles what that misses (abandoned PRs,
  failed polls, orphaned namespaces). For open PRs it closes the PR and
  lets the normal GitOps path do the teardown — it never fights the
  ApplicationSet.
- **Operated against SLOs.** 99% of previews ready within 5 minutes; 99%
  of open PRs reachable. Success rate and error-budget burn are on the
  Grafana dashboard, and [docs/slo.md](docs/slo.md) defines what happens
  when the budget runs out.
- **No long-lived cloud credentials anywhere.** GitHub Actions assumes
  narrowly-scoped IAM roles via OIDC federation; each role is restricted
  to its exact repo and task.
- **Everything is code, everything is gated.** 9 reusable Terraform
  modules; CI runs fmt / validate / tflint / checkov (142 checks passing)
  and posts plans as PR comments.

## Design decisions

[docs/architecture.md](docs/architecture.md) documents every non-obvious
choice phase by phase — including the bugs found by testing against the
real system rather than assuming: two opposite-direction Helm/ArgoCD
namespace-ownership conflicts, StatefulSet PVCs that outlive their
StatefulSet, ENI limits capping small nodes at 11 pods (fixed with prefix
delegation, 10× density), and Go-template parsing quirks in notification
routing.

## Repository layout

```
terraform/
├── bootstrap/         # one-time: S3 state bucket + DynamoDB lock table
├── modules/           # network, eks, ecr, github-oidc, argocd, kyverno,
│                      # karpenter, monitoring, spot-exporter, fis, budgets
└── envs/lab/          # the single environment (S3 backend)
charts/preview-app/    # Helm chart: app + Postgres + ALB Ingress (one preview)
argocd/                # ApplicationSet (PR generator) + notifications config
karpenter/             # preview NodePool + EC2NodeClass (spot-first, tainted)
policies/              # Kyverno ClusterPolicies + generated namespace guardrails
reaper/                # TTL reaper: Python, unit-tested, CronJob manifest
exporters/             # Prometheus exporter: spot savings + SLO measurements
monitoring/            # ServiceMonitors
dashboards/            # Grafana dashboard (auto-imported via sidecar)
docs/                  # architecture decisions, SLOs, captured evidence
.github/workflows/     # terraform CI, reaper CI, exporter CI
```

## Running it yourself

Prerequisites: an AWS account, Terraform ≥ 1.7, kubectl, helm, and the
`gh` CLI authenticated to a GitHub account that owns both repos.

```sh
# 1. One-time state backend
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # choose a unique bucket name
terraform init && terraform apply

# 2. The platform (~15 minutes)
cd ../envs/lab
cp terraform.tfvars.example terraform.tfvars   # your email, your repos
export TF_VAR_github_token=$(gh auth token)
terraform init && terraform apply

# 3. In-cluster config (CRD-based, applied once)
aws eks update-kubeconfig --name prlab-lab --region us-east-1
kubectl apply -f argocd/applicationset-previews.yaml
kubectl apply -f argocd/notifications.yaml
kubectl apply -f policies/
kubectl apply -f karpenter/nodepool-preview.yaml
kubectl apply -f reaper/cronjob.yaml
kubectl apply -f exporters/deployment.yaml
kubectl apply -f monitoring/servicemonitors.yaml
kubectl create configmap prlab-dashboard -n monitoring \
  --from-file=preview-platform.json=dashboards/preview-platform.json
kubectl label configmap prlab-dashboard -n monitoring grafana_dashboard=1
```

Open a PR on the demo app repo; the preview URL arrives as a PR comment.

Dashboards (both UIs are deliberately not exposed publicly — port-forward
only):

```sh
# Grafana - dashboard "prlab — Preview Platform"
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
kubectl get secret kps-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# ArgoCD
kubectl port-forward -n argocd svc/argocd-server 8080:443
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

Tear down with `terraform destroy` in `envs/lab`. The platform is designed
to apply and destroy cleanly: previews cost nothing when no PRs are open,
and the whole environment costs nothing when destroyed.

## Cost engineering

Designed for near-zero idle cost, and to be affordable to run on a
personal account:

- Preview capacity is spot-only-while-needed; Karpenter consolidates
  empty nodes away within a minute of the last preview closing.
- Single NAT gateway; no RDS (previews get ephemeral in-cluster Postgres —
  disposable environments don't need managed-database durability).
- ECR lifecycle policies expire PR images automatically; budget alarms
  exist before any compute does.
- The `apply → work → destroy` loop is a first-class workflow, not an
  afterthought.

## Related repository

[prlab-demo-app](https://github.com/Heramb04/prlab-demo-app) — the
application repo developers actually interact with: a FastAPI + Postgres
service whose health page reports its PR number, git SHA, and whether it's
running on a spot or on-demand node (read live from the Kubernetes API).
Its CI builds and pushes images via OIDC and never touches the cluster.

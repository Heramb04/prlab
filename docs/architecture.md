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

## Phase 1 — Cluster + one manual preview

### Why `terraform-aws-modules/eks` instead of hand-rolled EKS resources

Same reasoning as the network module: OIDC provider setup, node IAM roles,
security group rules for cluster<->node communication, and addon version
compatibility are all easy to get subtly wrong by hand and this module is
the de facto standard, actively maintained, version-pinned (`~> 20.37`).
`enable_cluster_creator_admin_permissions = true` grants the applying IAM
identity a cluster-admin EKS access entry automatically, so `terraform
apply` alone is enough to get a working `kubectl` — no separate manual
`aws-auth` ConfigMap edit, which is how EKS access used to have to be
granted before access entries existed.

### Why the system node group runs t3.small, not t3.medium as originally planned

Discovered mid-Phase-1: this burner account is on AWS's "Free Plan," which
turned out to **hard-block** On-Demand launches of any instance type
outside the free-tier-eligible list, not just meter them differently. The
first `terraform apply` attempt sat "Still creating..." for 18+ minutes
before a direct AWS API check (`aws autoscaling describe-scaling-activities`)
revealed the real cause: every launch attempt was failing instantly with
`InvalidParameterCombination - The specified instance type is not eligible
for Free Tier`, and EKS's own node group health check hadn't yet surfaced
it as an error. Free-tier-eligible On-Demand types are limited to
`t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, plus two flex types;
`t3.small` (x86_64, 2 vCPU/2GiB) was chosen over the `t4g.*` (ARM/Graviton)
options specifically to avoid multi-arch image build complexity for the
demo app and future addons. This is worth knowing before Phase 4: Karpenter
capacity choices need to respect the same Free Plan constraint (though spot
requests may not be subject to the same restriction — verify before
assuming an instance type works there too).

### Why EKS 1.34, not the account's default (1.36)

AWS defaults new clusters to the newest Standard Support version, but addon
and Helm chart compatibility (AWS Load Balancer Controller, EBS CSI driver,
metrics-server, and later Karpenter) tends to lag a release or two behind
the very newest control plane version in community documentation and
issue trackers. 1.34 is still Standard Support (not Extended, i.e. not
approaching end-of-life) with support into December 2026, so it's a boring,
current, well-documented choice rather than the bleeding edge.

### Why the AWS Load Balancer Controller and metrics-server are installed via a Terraform `helm_release`, not a manual `helm install`

Everything about this platform is meant to be `terraform apply` in, `terraform
destroy` out, with no undocumented manual steps in between (Phase 0's cost
discipline depends on that being true). Configuring the `kubernetes`/`helm`
Terraform providers with `exec`-based auth (`aws eks get-token`) against the
`eks` module's own outputs keeps cluster bootstrap fully declarative and
reproducible from a clean `terraform apply`, instead of relying on someone
remembering to run a `helm install` by hand after the cluster comes up.

### Why a `gp3` StorageClass is created explicitly

EKS ships a default `gp2` StorageClass (the older in-tree provisioner) but
does not create a `gp3` one even though the `aws-ebs-csi-driver` addon
supports it. gp3 is both cheaper and faster than gp2 at the same size, so
the EKS module creates one explicitly (`ebs.csi.aws.com` provisioner) for
preview Postgres PVCs to use, without touching the cluster's default.

### Why the demo app's container image is built by GitHub Actions instead of locally

This build environment has no container runtime available (no
docker/podman) to build and push an image directly. Rather than working
around that locally, the image build was moved to GitHub Actions using the
same OIDC-federation pattern as the Terraform-plan role — a second,
narrowly-scoped IAM role (`prlab-github-ecr-push`) trusted only for
`repo:Heramb04/prlab-demo-app:*`, permitted only to push to this one ECR
repository. This is exactly Phase 2's `ci.yml` requirement anyway (CI builds
artifacts, never touches the cluster), just introduced one phase earlier
than strictly necessary so Phase 1's manual preview has a real image to
install.

### Why Postgres is a StatefulSet, not a Deployment with a bare PVC

A single stateful pod technically works either way, but a Deployment
replacing a pod (e.g. during a node drain) can race: the new pod can be
scheduled before the old one has released its `ReadWriteOnce` EBS volume
attachment, and fails to mount. A StatefulSet's `volumeClaimTemplates` and
default rolling-update ordering (terminate-then-create for a single
replica) avoids that race — the standard reason Postgres-in-Kubernetes
tutorials reach for a StatefulSet even at replica count 1, and it matters
more once Phase 4 adds real node interruptions (spot reclaim) into the mix.

### Why the preview namespace isn't created by a chart template

The chart originally included a `templates/namespace.yaml` so it could set
`preview=true`/`pr-number=<n>` labels declaratively. In practice this
collided with Helm's own `--create-namespace` flag: that flag creates the
namespace *before* applying any release manifests and does **not** tag it
with Helm's ownership annotations, so the chart's own `Namespace` resource
then fails with "already exists" (a known Helm gotcha — a resource Helm
didn't create itself can't later be adopted into a release without manually
copying its ownership annotations across first). The chart now leaves
namespace creation to `--create-namespace` and a separate `kubectl label`
step; Phase 2's ArgoCD Application will set the same labels declaratively
via `syncPolicy.managedNamespaceMetadata`, which exists specifically to
avoid this exact conflict.

### Why the sslip.io hostname uses dashes, not dots, around the IP

`pr-0.54.235.16.247.sslip.io` (dots throughout) resolves to the wrong
address — sslip.io's parser doesn't reliably extract a 4-octet IP from the
middle of an all-dotted label chain once a text prefix like `pr-0` precedes
it. The documented-safe form for a subdomain-plus-IP is dashes around the
IP: `pr-0.54-235-16-247.sslip.io`, which resolves correctly. Worth knowing
before Phase 2 templates this per-PR — get the dash form wrong and every
preview URL silently resolves nowhere.

## Phase 2 — GitOps previews with ArgoCD

### Two Helm-vs-ArgoCD ownership gotchas, and why the fixes differ

Phase 1 removed the chart's `Namespace` template because the plain `helm`
CLI's `--create-namespace` flag creates the namespace *outside* Helm's
release tracking, so the chart's own `Namespace` resource then fails with
"already exists" (an ownership-annotation mismatch). Phase 2 hit the
mirror-image problem from ArgoCD's side: the Application's
`CreateNamespace=true` syncOption also creates the namespace, but does
**not** register it as a resource the Application manages - so when the PR
closes and the Application is pruned, everything explicitly declared in the
chart (Deployment, StatefulSet, Service, Ingress) got cleanly deleted, but
the namespace itself, and a StatefulSet-derived PVC still sitting inside
it, were silently left behind. Verified live with a real PR close, not
theorized - the "everything is gone, zero teardown pipeline" claim only
holds if you actually watch a namespace disappear.

The fix is opposite to Phase 1's: **add** `templates/namespace.yaml` back,
because ArgoCD's sync engine (unlike Helm's stricter ownership check)
adopts a pre-existing bare namespace into the Application's tracked
resources without conflict. The same file that broke a plain `helm
install` is required for a correct `helm install`-via-ArgoCD.

### Why StatefulSet PVCs need an explicit retention policy

Separately from the namespace gap: Kubernetes never auto-deletes a
`volumeClaimTemplate`-derived PVC when its StatefulSet is deleted - a
deliberate anti-data-loss default, since normally you don't want a
scale-down or redeploy to silently destroy a database's disk. Preview
Postgres is disposable by design, so `persistentVolumeClaimRetentionPolicy:
{ whenDeleted: Delete, whenScaled: Retain }` (Kubernetes 1.27+) opts back
into deletion explicitly. Without it, every closed PR would leak a 1Gi EBS
volume forever - a slow, invisible budget leak on a $140 total credit.

### Why the "preview ready" URL comes from `.app.status.summary.externalURLs`, not a templated sslip.io hostname

Phase 1's manual sslip.io hostname requires knowing the ALB's IP *before*
creating the Ingress - a chicken-and-egg problem with no clean answer for
a fully automated per-PR flow, since each preview's ALB IP isn't known
until after ArgoCD has already synced it. Rather than solve that, the
Ingress has no `spec.rules[].host` set at all (matches any host), and the
ArgoCD Notifications template reads `.app.status.summary.externalURLs`
instead - confirmed live to auto-populate from the Ingress's
`status.loadBalancer.ingress[].hostname` once the ALB is provisioned, with
no extra annotation required. The PR comment links the raw ALB hostname
rather than a human-friendly sslip.io URL; a real domain + Route53 (the
spec's other suggested option) would fix that, but wasn't in scope here.

### Why the PR-comment webhook uses `trimPrefix "pr-" .app.metadata.name` instead of a label lookup

Go's template dot-notation can't access a map key containing a hyphen -
`{{.app.labels.pr-number}}` fails to parse ("bad character U+002D '-'"),
because the parser reads it as `.app.labels.pr` followed by an invalid
bare `-number` token. The fix isn't `{{index .app.labels "pr-number"}}`
(which does work) but something even simpler: every Application is already
named `pr-<number>` by the ApplicationSet template, so trimming that fixed
prefix off `.app.metadata.name` gets the PR number without touching labels
at all.

### Why the ApplicationSet polls every 60 seconds, not the 30-minute default

The platform's own SLO is "preview ready within 5 minutes of PR open." A
30-minute poll interval would blow that budget on its own before a single
container even starts. 60 seconds keeps detection latency low while
staying far under GitHub's 5000 req/hr authenticated rate limit for a
single-repo poll.

### Why the ApplicationSet's PR generator and Notifications share one GitHub token, and why it's a personal PAT

Both need GitHub API access - one to list open PRs, one to post a comment
- and both read the same Kubernetes Secret (`argocd-notifications-secret`,
key `github-token`), avoiding provisioning the same credential twice. It's
sourced from `gh auth token` (this machine's already-authenticated GitHub
CLI session) at `terraform apply` time via `TF_VAR_github_token`, and never
printed or committed. Note this is a broadly-scoped personal token (`repo`,
`workflow`, ...), not a fine-grained PAT limited to just
`prlab-demo-app`'s pull requests and issues - an acceptable tradeoff for a
single-user lab, but the honest answer to "how would you scope this down
for a team" is a GitHub App with narrowly-defined permissions instead.

## Phase 3 — Policy + TTL safety net

### Why prefix delegation had to come first

t3.small's default ENI math (3 ENIs × 4 IPs) caps kubelet at **11 pods per
node**. System pods + ArgoCD already used 20 of the fleet's 22 slots —
Kyverno's controllers wouldn't have fit, let alone more previews. VPC CNI
prefix delegation assigns /28 prefixes (16 IPs) per ENI slot instead of
single IPs; combined with a nodeadm `maxPods: 110` override it lifts the
ceiling by an order of magnitude on the same instances, for free. Two
gotchas found live: (1) the eks module's `ami_type` must be set explicitly
or its user-data logic silently falls back to the AL2 template and drops
the nodeadm config — the node group only *reports* AL2023 because the EKS
API defaults it; (2) the vpc-cni addon move from `this` to
`before_compute` in the module races (create hit 409 before the delete
finished) — harmless, the re-apply converged, but "terraform exit 1 ≠
nothing worked": the node roll inside that same apply had already
succeeded.

### Why quota/limits are injected by a Kyverno generate policy, not the Helm chart

Chart-declared ResourceQuota/LimitRange only guards namespaces that chart
creates. A generate policy keyed on the `preview=true` namespace label
holds no matter how a preview namespace comes to exist — this chart, a
future second chart, or somebody's kubectl. The platform enforces its own
floor. (Verified: a bare `kubectl create namespace` + label got its quota
within ~2 seconds.) The background controller needs extra RBAC to create
core resources — granted via Kyverno's documented
`rbac.kyverno.io/aggregate-to-background-controller` label, see
`policies/kyverno-rbac.yaml`.

### An admission-ordering subtlety: why require-limits bites Deployments, not Pods

The API server's built-in LimitRanger plugin *defaults* missing
requests/limits on **Pods** during the mutating phase, before validating
webhooks run — so a bare Pod usually sails past the require-limits policy
with LimitRange-injected values. But LimitRanger never touches a
**Deployment's pod template**, and Kyverno autogen validates exactly that.
Net effect: the denial lands at Deployment admission (where ArgoCD also
reports it), and Pod-level defaulting acts as a second net rather than a
bypass. Worth knowing before writing "why didn't my policy fire?" bug
reports.

### Why the reaper closes PRs instead of deleting cluster resources

For an **open** PR, deleting the Application or namespace is futile: the
ApplicationSet regenerates the Application on its next 60s poll, and
selfHeal re-syncs the namespace. The only teardown that *sticks* is
removing the PR from the generator's result set — i.e. closing the PR. So
past TTL the reaper posts a comment and closes the PR via the GitHub API,
and teardown flows through the exact same ArgoCD prune path as a human
closing it. Direct in-cluster deletion happens only for **orphans**:
closed PRs whose namespace is still around after a grace period — exactly
the silent-prune-failure mode we hit live in Phase 2. Defense in depth,
informed by an actual observed failure, not a hypothetical. A pleasant
side effect: the reaper's Kubernetes RBAC is tiny (list/delete namespaces,
delete Applications) because for the common case it touches nothing
in-cluster at all.

### Why warnings are tracked with a PR label, not comment-history scanning

Idempotency across reaper runs needs "did I already warn?" to be cheap and
reliable. Scanning comment history is O(comments) and fragile against
edited/deleted comments; a `preview-ttl-warned` label is one API call to
check (it rides along on the PR GET) and survives everything short of a
human removing it — which is a reasonable "snooze" gesture anyway.

### Why the ApplicationSet template now sets the resources-finalizer

Deleting an ArgoCD Application by any path other than the ApplicationSet's
own prune (reaper, kubectl, UI) is **non-cascading** unless the
Application carries `resources-finalizer.argocd.argoproj.io` — the object
vanishes and every deployed resource stays behind, the same orphan class
as Phase 2's namespace bug. The ApplicationSet's own prune cascades
regardless, which is why Phase 2's close-PR test passed without it; the
finalizer matters the moment anything else (like the reaper) deletes an
Application.

### Why the reaper is a Python CronJob, not a Kyverno CleanupPolicy

Kyverno's cleanup controller can delete resources on a schedule, but the
reaper's job is a *workflow*, not a deletion: look up the PR's state on
GitHub, warn on the PR, close the PR, and only delete directly in the
orphan case. That needs an external API client and branching logic — a
small, unit-testable Python program is the honest tool. The cleanup
controller is disabled in the Kyverno install to save a pod's worth of
memory on t3.smalls.

### Why the preview namespace has no custom "created-at" annotation

Kubernetes already stamps every object with an immutable
`metadata.creationTimestamp` at the API server. A Helm-templated `{{ now }}`
annotation would look right on first install but silently update on every
`helm upgrade` (e.g. a new commit pushed to the same open PR), which is the
wrong value for a TTL reaper to trust. The reaper (Phase 3) reads
`creationTimestamp` directly instead of trusting a value Helm would
otherwise clobber.

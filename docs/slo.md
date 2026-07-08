# Platform SLOs & error budget policy

The preview platform is a product; its users are engineers opening PRs.
These are the promises it makes to them, how they're measured, and what
happens when the promises break. Written like a real error-budget policy
because the discipline is the point — a lab-sized platform with real SLOs
beats a big platform with vibes.

## SLOs

| SLO | Target | Measured as |
|---|---|---|
| **Readiness latency** | 99% of previews ready within **5 minutes** of PR open, over a 30-day window | `prlab_preview_ready_seconds` = ArgoCD Application first `deployedAt` − GitHub PR `created_at`; success = ≤ 300s |
| **Availability** | 99% of open PRs have a reachable preview at any given time | Open-PR Applications in `Synced+Healthy` state ÷ all open-PR Applications (ArgoCD `argocd_app_info` metrics) |

### Why these two

Readiness latency is the product promise ("opening a PR *is* the
provisioning action — and it's fast"). Availability is the trust promise
(a preview that died silently is worse than none, because reviewers act on
stale conclusions). Everything else — spot savings, node counts,
interruption counts — is diagnostic, not a promise to users.

### What counts against the budget

- CI build time, ApplicationSet poll delay, image pull, pod start, ALB
  provisioning — **all of it counts** toward the 5 minutes. Users don't
  care whose fault the wait is; the SLO clock starts at PR open.
- Spot interruptions do **not** get an exemption. The platform chose spot;
  surviving interruptions inside the availability target is the
  platform's job (Karpenter's ~75s replace cycle fits comfortably).
- Previews broken by the PR's own code (app crashloops on a bug the PR
  introduced) do **not** count against the platform. That's the product
  working as intended — showing the author their bug.

## Error budget

99% over 30 days ≈ **7.2 hours** of unavailability budget, or 1 in 100
previews allowed to miss the readiness target.

Budget remaining is on the Grafana dashboard
(`1 - (misses / measured) / 0.01`, as a fraction of budget left).

## Policy when the budget is exhausted

1. **Freeze platform feature work.** No new capabilities (new stretch
   goals, new node types, new automation) until the budget is back.
   Reliability work only: whatever made previews slow or unreachable gets
   fixed first.
2. **Every burn gets a written cause.** One paragraph in
   `docs/incidents/` per budget-burning event: what user-visible promise
   broke, the mechanism, and the fix. (The two Phase 2/3 cleanup bugs
   would each have been one of these had the SLO existed then.)
3. **Repeat causes escalate to design changes.** The second time the same
   mechanism burns budget, the fix must be structural (e.g. if
   ApplicationSet poll latency keeps eating the readiness budget, switch
   the generator from polling to webhooks), not another patch.
4. **Budget intact at month end → spend it deliberately.** An unspent
   error budget is permission to take risk: chaos experiments (more
   synthetic interruptions), Karpenter version bumps, dependency updates.

## Known measurement gaps (honesty section)

- The readiness counters live in the exporter's memory and reset when it
  restarts; a production build would compute this from durable events
  (Prometheus recording rules over a webhook-fed event stream).
- Availability is currently derived from ArgoCD health, which is a proxy:
  an app can be `Healthy` while the ALB misroutes. A black-box HTTP
  prober per preview (blackbox_exporter walking open-PR URLs) is the
  honest upgrade and a natural Phase 6.
- 30-day windows outlive the lab's apply→destroy cycles; in practice the
  window is "since this cluster came up." The math and the policy are
  what transfer to a long-lived platform.

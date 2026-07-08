# Spot interruption → automatic recovery (captured live, 2026-07-08)

FIS isn't available on this account (Free Plan, no subscription), so the
interruption was injected as a synthetic `EC2 Spot Instance Interruption
Warning` event sent directly to Karpenter's SQS interruption queue — the
exact same message EventBridge would deliver for a real reclamation or an
FIS experiment, driving the same controller code path.

## Timeline (from Karpenter logs + kubectl watch)

| T+ | Event |
|------|-------|
| 0s (11:53:54Z) | Synthetic interruption warning for `i-07108b3d79def68d1` (spot, t3.small, us-east-1a, running preview pr-4) sent to SQS |
| +2s | Karpenter tainted the node |
| +4s | Replacement NodeClaim computed and created |
| +6s | Replacement instance launched |
| +42s | Replacement node registered with the cluster |
| +43s | Old node + NodeClaim deleted; pods rescheduling |
| +75s (11:55:09Z) | Both preview pods Running on the replacement node, EBS volume re-attached |

Preview reachable over HTTP immediately after; Postgres accepted writes
(PVC survived and re-attached).

## The unplanned bonus: on-demand fallback, observed

The replacement came up **on-demand**, not spot. Why: Karpenter briefly
marks a spot pool unavailable after an interruption, and the preview's
EBS volume pins it to us-east-1a — with the NodePool constrained to
t3.small (Free Plan) the only remaining option in that AZ was on-demand.
That is precisely the designed degradation path ("spot-first, on-demand
fallback") firing under real conditions, not a slideware claim.

## Epilogue: consolidation closed the loop unprompted

~5 minutes after the fallback, Karpenter's consolidation
(`WhenEmptyOrUnderutilized`) noticed the on-demand node was more expensive
than available spot, disrupted it (12:00:21Z, "disrupting node(s)"), and
moved the preview onto a fresh spot node. The spot-savings exporter
confirmed: `prlab_preview_nodes{lifecycle="spot"} 1`, on-demand 0, saving
$0.0128/hour (~62%) versus on-demand for the same capacity. Interruption →
fallback → automatic return to cheapest capacity, with zero human action
at any step.

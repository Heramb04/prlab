"""TTL reaper decision logic for prlab preview environments.

Pure logic only - no Kubernetes or GitHub imports - so unit tests need no
mocking framework, just plain dataclasses. All I/O lives in clients.py and
is wired up in main.py.

Design constraints this encodes (see docs/architecture.md for the full
reasoning):

- For an OPEN PR past TTL, nothing in-cluster is deleted directly: the
  ApplicationSet would recreate anything we delete within one poll cycle
  (60s). Instead the reaper closes the PR itself, and teardown flows
  through the exact same ArgoCD prune path as a human closing it.
- For a CLOSED PR whose namespace still exists (an orphan - ArgoCD's
  prune failed or was missed), the generator won't recreate anything, so
  direct deletion is safe and is the only remaining cleanup path.
- Warnings are posted once per PR, tracked via a PR label rather than
  scanning comment history: idempotent across reaper runs and cheap to
  check.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from datetime import datetime, timedelta

WARNED_LABEL = "preview-ttl-warned"


class Action(enum.Enum):
    NONE = "none"
    WARN = "warn"
    CLOSE_PR = "close-pr"
    REAP_ORPHAN = "reap-orphan"


@dataclass
class PreviewNamespace:
    name: str
    pr_number: int | None  # None if the pr-number label is missing/garbage
    created_at: datetime


@dataclass
class PullRequest:
    number: int
    state: str  # "open" | "closed"
    closed_at: datetime | None
    labels: set[str] = field(default_factory=set)


def decide(
    ns: PreviewNamespace,
    pr: PullRequest | None,
    now: datetime,
    ttl: timedelta,
    warn_before: timedelta,
    orphan_grace: timedelta,
) -> Action:
    """Decide what to do about one preview namespace.

    `pr` is None when the PR lookup failed or the namespace has no usable
    pr-number label - treated as an orphan (nothing will ever clean it up
    otherwise), but only after the grace period measured from namespace
    creation, so a transient GitHub API failure can't cause a deletion.
    """
    if pr is None:
        if now - ns.created_at >= orphan_grace:
            return Action.REAP_ORPHAN
        return Action.NONE

    if pr.state == "closed":
        # ArgoCD prunes on close within its poll interval; if the namespace
        # is still here after the grace period, that path failed.
        reference = pr.closed_at if pr.closed_at is not None else ns.created_at
        if now - reference >= orphan_grace:
            return Action.REAP_ORPHAN
        return Action.NONE

    age = now - ns.created_at
    if age >= ttl:
        return Action.CLOSE_PR
    if age >= ttl - warn_before and WARNED_LABEL not in pr.labels:
        return Action.WARN
    return Action.NONE


def run(kube, github, now: datetime, ttl: timedelta, warn_before: timedelta,
        orphan_grace: timedelta, dry_run: bool = False) -> dict[str, Action]:
    """One reaper pass. Returns {namespace: action-taken} for logging/tests.

    `kube` and `github` are duck-typed clients (see clients.py):
      kube.list_preview_namespaces() -> list[PreviewNamespace]
      kube.delete_preview(ns_name)   # Application (if any) + namespace
      github.get_pr(number) -> PullRequest | None
      github.warn(pr_number, hours_left)   # comment + warned label
      github.close_with_comment(pr_number)
    """
    results: dict[str, Action] = {}
    for ns in kube.list_preview_namespaces():
        pr = github.get_pr(ns.pr_number) if ns.pr_number is not None else None
        action = decide(ns, pr, now, ttl, warn_before, orphan_grace)
        results[ns.name] = action
        if dry_run or action is Action.NONE:
            continue
        if action is Action.WARN:
            hours_left = (ttl - (now - ns.created_at)) / timedelta(hours=1)
            github.warn(ns.pr_number, hours_left)
        elif action is Action.CLOSE_PR:
            github.close_with_comment(ns.pr_number)
        elif action is Action.REAP_ORPHAN:
            kube.delete_preview(ns.name)
    return results

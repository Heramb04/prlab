"""Unit tests for the reaper's decision logic and orchestration.

Pure-logic tests: no kubernetes/requests imports, no mocking framework -
duck-typed fakes are enough because reaper.py takes clients as parameters.
"""

from datetime import datetime, timedelta, timezone

from reaper import (
    WARNED_LABEL,
    Action,
    PreviewNamespace,
    PullRequest,
    decide,
    run,
)

NOW = datetime(2026, 7, 8, 12, 0, 0, tzinfo=timezone.utc)
TTL = timedelta(hours=48)
WARN_BEFORE = timedelta(hours=6)
GRACE = timedelta(minutes=30)


def ns(age: timedelta, pr_number: int | None = 1) -> PreviewNamespace:
    return PreviewNamespace(name="pr-1", pr_number=pr_number, created_at=NOW - age)


def open_pr(labels: set[str] | None = None) -> PullRequest:
    return PullRequest(number=1, state="open", closed_at=None, labels=labels or set())


def closed_pr(closed_ago: timedelta) -> PullRequest:
    return PullRequest(number=1, state="closed", closed_at=NOW - closed_ago)


def d(namespace, pr):
    return decide(namespace, pr, NOW, TTL, WARN_BEFORE, GRACE)


class TestDecide:
    def test_young_namespace_open_pr_untouched(self):
        assert d(ns(age=timedelta(hours=1)), open_pr()) is Action.NONE

    def test_just_before_warn_window_untouched(self):
        assert d(ns(age=TTL - WARN_BEFORE - timedelta(minutes=1)), open_pr()) is Action.NONE

    def test_inside_warn_window_warns(self):
        assert d(ns(age=TTL - WARN_BEFORE + timedelta(minutes=1)), open_pr()) is Action.WARN

    def test_warn_is_idempotent_via_label(self):
        pr = open_pr(labels={WARNED_LABEL})
        assert d(ns(age=TTL - timedelta(hours=1)), pr) is Action.NONE

    def test_past_ttl_closes_pr(self):
        assert d(ns(age=TTL + timedelta(minutes=1)), open_pr()) is Action.CLOSE_PR

    def test_past_ttl_closes_even_if_already_warned(self):
        pr = open_pr(labels={WARNED_LABEL})
        assert d(ns(age=TTL + timedelta(hours=1)), pr) is Action.CLOSE_PR

    def test_closed_pr_within_grace_untouched(self):
        # ArgoCD's prune may still be in flight; don't race it.
        assert d(ns(age=timedelta(hours=2)), closed_pr(timedelta(minutes=5))) is Action.NONE

    def test_closed_pr_past_grace_is_orphan(self):
        assert d(ns(age=timedelta(hours=2)), closed_pr(timedelta(hours=1))) is Action.REAP_ORPHAN

    def test_closed_pr_missing_closed_at_uses_ns_age(self):
        pr = PullRequest(number=1, state="closed", closed_at=None)
        assert d(ns(age=timedelta(hours=2)), pr) is Action.REAP_ORPHAN
        assert d(ns(age=timedelta(minutes=5)), pr) is Action.NONE

    def test_missing_pr_is_orphan_after_grace(self):
        assert d(ns(age=timedelta(hours=2), pr_number=None), None) is Action.REAP_ORPHAN

    def test_missing_pr_within_grace_untouched(self):
        # Transient GitHub API failure must never cause an instant delete.
        assert d(ns(age=timedelta(minutes=5), pr_number=None), None) is Action.NONE


class FakeKube:
    def __init__(self, namespaces):
        self.namespaces = namespaces
        self.deleted = []

    def list_preview_namespaces(self):
        return self.namespaces

    def delete_preview(self, ns_name):
        self.deleted.append(ns_name)


class FakeGitHub:
    def __init__(self, prs):
        self.prs = prs
        self.warned = []
        self.closed = []

    def get_pr(self, number):
        return self.prs.get(number)

    def warn(self, pr_number, hours_left):
        self.warned.append((pr_number, round(hours_left)))

    def close_with_comment(self, pr_number):
        self.closed.append(pr_number)


class TestRun:
    def test_mixed_fleet_gets_correct_actions(self):
        namespaces = [
            PreviewNamespace("pr-1", 1, NOW - timedelta(hours=1)),   # young
            PreviewNamespace("pr-2", 2, NOW - timedelta(hours=44)),  # warn window
            PreviewNamespace("pr-3", 3, NOW - timedelta(hours=50)),  # past TTL
            PreviewNamespace("pr-4", 4, NOW - timedelta(hours=2)),   # orphan
        ]
        github = FakeGitHub(
            {
                1: open_pr(),
                2: PullRequest(2, "open", None),
                3: PullRequest(3, "open", None),
                4: PullRequest(4, "closed", NOW - timedelta(hours=1)),
            }
        )
        kube = FakeKube(namespaces)

        results = run(kube, github, NOW, TTL, WARN_BEFORE, GRACE)

        assert results == {
            "pr-1": Action.NONE,
            "pr-2": Action.WARN,
            "pr-3": Action.CLOSE_PR,
            "pr-4": Action.REAP_ORPHAN,
        }
        assert github.warned == [(2, 4)]
        assert github.closed == [3]
        assert kube.deleted == ["pr-4"]

    def test_dry_run_decides_but_touches_nothing(self):
        namespaces = [PreviewNamespace("pr-3", 3, NOW - timedelta(hours=50))]
        github = FakeGitHub({3: open_pr()})
        kube = FakeKube(namespaces)

        results = run(kube, github, NOW, TTL, WARN_BEFORE, GRACE, dry_run=True)

        assert results == {"pr-3": Action.CLOSE_PR}
        assert github.closed == []
        assert kube.deleted == []

    def test_unparseable_pr_label_skips_github_and_reaps_after_grace(self):
        namespaces = [PreviewNamespace("pr-bad", None, NOW - timedelta(hours=2))]
        github = FakeGitHub({})
        kube = FakeKube(namespaces)

        results = run(kube, github, NOW, TTL, WARN_BEFORE, GRACE)

        assert results == {"pr-bad": Action.REAP_ORPHAN}
        assert kube.deleted == ["pr-bad"]

"""Real Kubernetes and GitHub clients for the TTL reaper.

Kept separate from reaper.py so unit tests never import kubernetes/requests.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

import requests
from kubernetes import client as k8s_client
from kubernetes import config as k8s_config

from reaper import PreviewNamespace, PullRequest, WARNED_LABEL

log = logging.getLogger("reaper")

WARN_COMMENT = (
    "⏳ This preview environment is approaching its TTL and will be "
    "reaped in about {hours_left:.0f}h. The PR will be closed automatically "
    "at that point; close and reopen the PR afterwards if you still need a "
    "preview."
)
CLOSE_COMMENT = (
    "☠️ This preview environment exceeded its TTL and has been "
    "reaped. Closing the PR; reopen it to get a fresh preview."
)


class KubeClient:
    def __init__(self, argocd_namespace: str = "argocd"):
        k8s_config.load_incluster_config()
        self.core = k8s_client.CoreV1Api()
        self.custom = k8s_client.CustomObjectsApi()
        self.argocd_namespace = argocd_namespace

    def list_preview_namespaces(self) -> list[PreviewNamespace]:
        out = []
        for item in self.core.list_namespace(label_selector="preview=true").items:
            if item.status.phase == "Terminating":
                continue  # already going away; don't double-act
            labels = item.metadata.labels or {}
            try:
                pr_number = int(labels["pr-number"])
            except (KeyError, ValueError):
                pr_number = None
            out.append(
                PreviewNamespace(
                    name=item.metadata.name,
                    pr_number=pr_number,
                    created_at=item.metadata.creation_timestamp,
                )
            )
        return out

    def delete_preview(self, ns_name: str) -> None:
        # Delete the Application first if it still exists (cascades via the
        # resources finalizer set in the ApplicationSet template), then the
        # namespace itself. Both tolerate 404: either may already be gone.
        try:
            self.custom.delete_namespaced_custom_object(
                group="argoproj.io",
                version="v1alpha1",
                namespace=self.argocd_namespace,
                plural="applications",
                name=ns_name,
            )
            log.info("deleted Application %s", ns_name)
        except k8s_client.ApiException as exc:
            if exc.status != 404:
                raise
        try:
            self.core.delete_namespace(ns_name)
            log.info("deleted namespace %s", ns_name)
        except k8s_client.ApiException as exc:
            if exc.status != 404:
                raise


class GitHubClient:
    def __init__(self, repo: str, token: str):
        self.repo = repo
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
            }
        )
        self.base = f"https://api.github.com/repos/{repo}"

    def get_pr(self, number: int) -> PullRequest | None:
        resp = self.session.get(f"{self.base}/pulls/{number}", timeout=10)
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        data = resp.json()
        closed_at = (
            datetime.fromisoformat(data["closed_at"].replace("Z", "+00:00"))
            if data.get("closed_at")
            else None
        )
        return PullRequest(
            number=number,
            state=data["state"],
            closed_at=closed_at,
            labels={label["name"] for label in data.get("labels", [])},
        )

    def warn(self, pr_number: int, hours_left: float) -> None:
        self._comment(pr_number, WARN_COMMENT.format(hours_left=hours_left))
        # Adding a label whose name doesn't exist yet auto-creates it.
        resp = self.session.post(
            f"{self.base}/issues/{pr_number}/labels",
            json={"labels": [WARNED_LABEL]},
            timeout=10,
        )
        resp.raise_for_status()
        log.info("warned PR #%s (%.1fh left)", pr_number, hours_left)

    def close_with_comment(self, pr_number: int) -> None:
        self._comment(pr_number, CLOSE_COMMENT)
        resp = self.session.patch(
            f"{self.base}/pulls/{pr_number}", json={"state": "closed"}, timeout=10
        )
        resp.raise_for_status()
        log.info("closed PR #%s past TTL", pr_number)

    def _comment(self, pr_number: int, body: str) -> None:
        resp = self.session.post(
            f"{self.base}/issues/{pr_number}/comments", json={"body": body}, timeout=10
        )
        resp.raise_for_status()

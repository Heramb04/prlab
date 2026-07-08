"""Entrypoint: read config from env, wire clients, run one reaper pass."""

import logging
import os
import sys
from datetime import datetime, timedelta, timezone

from clients import GitHubClient, KubeClient
from reaper import run


def env_hours(name: str, default: float) -> timedelta:
    return timedelta(hours=float(os.environ.get(name, default)))


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    ttl = env_hours("TTL_HOURS", 48)
    warn_before = env_hours("WARN_BEFORE_HOURS", 6)
    orphan_grace = env_hours("ORPHAN_GRACE_HOURS", 0.5)
    dry_run = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")

    repo = os.environ["GITHUB_REPO"]
    token = os.environ["GITHUB_TOKEN"]

    results = run(
        kube=KubeClient(),
        github=GitHubClient(repo, token),
        now=datetime.now(timezone.utc),
        ttl=ttl,
        warn_before=warn_before,
        orphan_grace=orphan_grace,
        dry_run=dry_run,
    )
    for ns, action in results.items():
        logging.info("%s -> %s%s", ns, action.value, " (dry-run)" if dry_run else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())

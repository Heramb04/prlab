"""Platform exporter: spot savings + preview-readiness SLO metrics.

Part 1 (FinOps): every interval, list running instances provisioned by the
preview NodePool (tag karpenter.sh/nodepool=preview), look up the current
spot price for each, and compare against the on-demand price for the same
type.

Part 2 (SLO): for every preview Application, measure "time from PR open to
preview ready" = ArgoCD's first recorded deployment (status.history[0]
.deployedAt) minus the PR's createdAt from GitHub. Each PR is measured
once and remembered in memory; counters expose how many previews were
measured and how many met the 5-minute target, from which Grafana computes
the SLO success rate and error budget. In-memory history resets on
restart - acceptable for a lab (a production build would drive this from
recording rules over an event stream instead, noted in docs).

Exposes plain-text Prometheus metrics on :9100/metrics via stdlib
http.server - no prometheus_client dependency needed for a handful of
gauges/counters.

On-demand prices are a small static table (us-east-1, Linux) rather than
calls to the AWS Pricing API: the Pricing API needs different IAM, a
different endpoint, and returns a 200-line JSON per SKU - not worth it for
the one instance family the Free Plan account can launch. Documented
tradeoff; extend the table if the NodePool ever widens.
"""

import json
import logging
import os
import ssl
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3

log = logging.getLogger("platform-exporter")

REGION = os.environ.get("AWS_REGION", "us-east-1")
NODEPOOL_TAG = os.environ.get("NODEPOOL_TAG", "preview")
SCRAPE_INTERVAL_S = int(os.environ.get("SCRAPE_INTERVAL_S", "60"))
GITHUB_REPO = os.environ.get("GITHUB_REPO", "Heramb04/prlab-demo-app")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
SLO_TARGET_SECONDS = int(os.environ.get("SLO_TARGET_SECONDS", "300"))

_SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

# us-east-1 Linux on-demand, USD/hour.
ON_DEMAND_USD_PER_HOUR = {
    "t3.small": 0.0208,
    "t3.micro": 0.0104,
    "t3.medium": 0.0416,
    "t3a.small": 0.0188,
    "t3a.medium": 0.0376,
}

_state: dict = {"metrics": "", "updated": 0.0}

# pr number -> ready_seconds, measured once per PR for this exporter's
# lifetime (Application history[0] is immutable once written).
_slo_measured: dict[int, float] = {}


def _iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _k8s_get(path: str):
    with open(f"{_SA_DIR}/token") as f:
        token = f.read()
    ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
    req = urllib.request.Request(
        f"https://kubernetes.default.svc{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        return json.load(resp)


def _github_pr_created_at(number: int) -> datetime | None:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{GITHUB_REPO}/pulls/{number}",
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return _iso(json.load(resp)["created_at"])
    except Exception:  # noqa: BLE001 - PR may be gone; skip, retry next pass
        log.exception("PR #%s lookup failed", number)
        return None


def collect_slo() -> str:
    """Measure preview-ready latency for any not-yet-measured preview app."""
    apps = _k8s_get(
        "/apis/argoproj.io/v1alpha1/namespaces/argocd/applications"
        "?labelSelector=preview%3Dtrue"
    )["items"]
    for app in apps:
        try:
            pr = int(app["metadata"]["labels"]["pr-number"])
        except (KeyError, ValueError):
            continue
        if pr in _slo_measured:
            continue
        history = app.get("status", {}).get("history", [])
        if not history:
            continue  # not deployed yet; measure on a later pass
        first_deployed = _iso(history[0]["deployedAt"])
        created = _github_pr_created_at(pr)
        if created is None:
            continue
        ready_s = max((first_deployed - created).total_seconds(), 0.0)
        _slo_measured[pr] = ready_s
        log.info("PR #%s preview ready in %.0fs", pr, ready_s)

    within = sum(1 for v in _slo_measured.values() if v <= SLO_TARGET_SECONDS)
    lines = [
        "# HELP prlab_preview_slo_target_seconds Readiness SLO target (PR open -> preview deployed).",
        "# TYPE prlab_preview_slo_target_seconds gauge",
        f"prlab_preview_slo_target_seconds {SLO_TARGET_SECONDS}",
        "# HELP prlab_previews_measured_total Previews measured since exporter start.",
        "# TYPE prlab_previews_measured_total counter",
        f"prlab_previews_measured_total {len(_slo_measured)}",
        "# HELP prlab_previews_ready_within_slo_total Previews that met the readiness target.",
        "# TYPE prlab_previews_ready_within_slo_total counter",
        f"prlab_previews_ready_within_slo_total {within}",
        "# HELP prlab_preview_ready_seconds Seconds from PR open to first successful deploy.",
        "# TYPE prlab_preview_ready_seconds gauge",
    ]
    lines += [
        f'prlab_preview_ready_seconds{{pr="{pr}"}} {secs:.0f}'
        for pr, secs in sorted(_slo_measured.items())
    ]
    return "\n".join(lines) + "\n"


def collect(ec2) -> str:
    resp = ec2.describe_instances(
        Filters=[
            {"Name": f"tag:karpenter.sh/nodepool", "Values": [NODEPOOL_TAG]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    instances = [
        i
        for r in resp["Reservations"]
        for i in r["Instances"]
    ]
    spot = [i for i in instances if i.get("InstanceLifecycle") == "spot"]

    # One spot-price lookup per distinct (type, az) pair actually running.
    spot_price: dict[tuple[str, str], float] = {}
    for inst in spot:
        key = (inst["InstanceType"], inst["Placement"]["AvailabilityZone"])
        if key not in spot_price:
            hist = ec2.describe_spot_price_history(
                InstanceTypes=[key[0]],
                AvailabilityZone=key[1],
                ProductDescriptions=["Linux/UNIX"],
                MaxResults=1,
            )["SpotPriceHistory"]
            spot_price[key] = float(hist[0]["SpotPrice"]) if hist else 0.0

    spot_hourly = sum(
        spot_price[(i["InstanceType"], i["Placement"]["AvailabilityZone"])] for i in spot
    )
    ondemand_equiv = sum(
        ON_DEMAND_USD_PER_HOUR.get(i["InstanceType"], 0.0) for i in spot
    )

    lines = [
        "# HELP prlab_preview_nodes Running preview-NodePool instances by lifecycle.",
        "# TYPE prlab_preview_nodes gauge",
        f'prlab_preview_nodes{{lifecycle="spot"}} {len(spot)}',
        f'prlab_preview_nodes{{lifecycle="on-demand"}} {len(instances) - len(spot)}',
        "# HELP prlab_spot_hourly_cost_usd Current spot $/hour for preview nodes.",
        "# TYPE prlab_spot_hourly_cost_usd gauge",
        f"prlab_spot_hourly_cost_usd {spot_hourly:.6f}",
        "# HELP prlab_ondemand_equivalent_hourly_cost_usd What the same nodes would cost on-demand, $/hour.",
        "# TYPE prlab_ondemand_equivalent_hourly_cost_usd gauge",
        f"prlab_ondemand_equivalent_hourly_cost_usd {ondemand_equiv:.6f}",
        "# HELP prlab_spot_hourly_savings_usd Estimated $/hour saved by using spot.",
        "# TYPE prlab_spot_hourly_savings_usd gauge",
        f"prlab_spot_hourly_savings_usd {max(ondemand_equiv - spot_hourly, 0.0):.6f}",
    ]
    return "\n".join(lines) + "\n"


def refresher():
    ec2 = boto3.client("ec2", region_name=REGION)
    while True:
        # Collect halves independently: a GitHub hiccup must not blank the
        # FinOps metrics and vice versa. Each half keeps its last-good text.
        parts = {}
        try:
            parts["savings"] = collect(ec2)
        except Exception:  # noqa: BLE001
            log.exception("savings collect failed; keeping stale half")
        try:
            parts["slo"] = collect_slo()
        except Exception:  # noqa: BLE001
            log.exception("slo collect failed; keeping stale half")
        _state.update(parts)
        _state["metrics"] = _state.get("savings", "") + _state.get("slo", "")
        _state["updated"] = time.time()
        time.sleep(SCRAPE_INTERVAL_S)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - stdlib interface
        if self.path == "/metrics":
            body = _state["metrics"].encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
        elif self.path == "/healthz":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        else:
            body = b"not found"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # quiet access logs
        pass


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    threading.Thread(target=refresher, daemon=True).start()
    HTTPServer(("0.0.0.0", 9100), Handler).serve_forever()

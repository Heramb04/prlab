"""Prometheus exporter: estimated $ saved by running previews on spot.

Every scrape interval it lists running instances provisioned by the
preview NodePool (tag karpenter.sh/nodepool=preview), looks up the current
spot price for each, and compares against the on-demand price for the same
type. Exposes plain-text Prometheus metrics on :9100/metrics via stdlib
http.server - no prometheus_client dependency needed for a handful of
gauges.

On-demand prices are a small static table (us-east-1, Linux) rather than
calls to the AWS Pricing API: the Pricing API needs different IAM, a
different endpoint, and returns a 200-line JSON per SKU - not worth it for
the one instance family the Free Plan account can launch. Documented
tradeoff; extend the table if the NodePool ever widens.
"""

import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3

log = logging.getLogger("spot-savings")

REGION = os.environ.get("AWS_REGION", "us-east-1")
NODEPOOL_TAG = os.environ.get("NODEPOOL_TAG", "preview")
SCRAPE_INTERVAL_S = int(os.environ.get("SCRAPE_INTERVAL_S", "60"))

# us-east-1 Linux on-demand, USD/hour.
ON_DEMAND_USD_PER_HOUR = {
    "t3.small": 0.0208,
    "t3.micro": 0.0104,
    "t3.medium": 0.0416,
    "t3a.small": 0.0188,
    "t3a.medium": 0.0376,
}

_state: dict = {"metrics": "", "updated": 0.0}


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
        try:
            _state["metrics"] = collect(ec2)
            _state["updated"] = time.time()
        except Exception:  # noqa: BLE001 - keep serving last-good metrics
            log.exception("collect failed; serving stale metrics")
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

#!/usr/bin/env python3
"""Mesure HTTP de l'endpoint readiness ; ne simule pas un parcours OIDC/SAML."""
import argparse
import concurrent.futures
import csv
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--host", required=True, help="FQDN Keycloak")
parser.add_argument("--vip", required=True, help="VIP d'entrée")
parser.add_argument("--scheme", choices=("http", "https"), default="https")
parser.add_argument("--port", type=int, help="Port ; 80 en HTTP ou 443 en HTTPS par défaut")
parser.add_argument("--requests", type=int, default=100)
parser.add_argument("--concurrency", type=int, default=4)
parser.add_argument("--path", default="/realms/master/.well-known/openid-configuration")
parser.add_argument("--insecure", action="store_true", help="Ignorer la validation CA TLS (uniquement pour certificat autosigné de test)")
parser.add_argument("--output", default="output/http-benchmark.csv")
args = parser.parse_args()
if not 1 <= args.requests <= 100000 or not 1 <= args.concurrency <= 256:
    parser.error("Bornes requests/concurrency invalides")
port = args.port or (443 if args.scheme == "https" else 80)
if not 1 <= port <= 65535:
    parser.error("Port invalide")


def measure(index: int) -> dict:
    url = f"{args.scheme}://{args.host}:{port}{args.path}"
    cmd = [
        "curl", "--noproxy", "*", "--resolve", f"{args.host}:{port}:{args.vip}",
        "--connect-timeout", "5", "--max-time", "30", "-sS", "-o", "/dev/null",
        "-w", "%{http_code},%{time_total}",
    ]
    if args.scheme == "https":
        cmd.append("--fail")
        if args.insecure:
            cmd.append("--insecure")
    cmd.append(url)
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    try:
        code, elapsed = result.stdout.split(",")
        latency = float(elapsed) * 1000
    except (ValueError, TypeError):
        code, latency = "000", 30000.0
    return {
        "request": index,
        "http_code": code,
        "latency_ms": round(latency, 3),
        "curl_exit": result.returncode,
    }


with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
    rows = list(pool.map(measure, range(args.requests)))
output = Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("w", newline="", encoding="utf-8") as stream:
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
latencies = sorted(row["latency_ms"] for row in rows)


def percentile(fraction: float) -> float:
    return latencies[min(len(latencies) - 1, int((len(latencies) - 1) * fraction))]


errors = sum(row["http_code"] != "200" or row["curl_exit"] != 0 for row in rows)
print(
    f"n={len(rows)} errors={errors} p50={percentile(.50):.2f}ms "
    f"p95={percentile(.95):.2f}ms p99={percentile(.99):.2f}ms"
)
raise SystemExit(1 if errors else 0)

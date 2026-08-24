#!/usr/bin/env python3
"""Compare a k6 summary-export against a stored baseline."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def metric_values(summary: dict[str, Any], name: str) -> dict[str, Any]:
    metrics = summary.get("metrics") or {}
    metric = metrics.get(name)
    if not isinstance(metric, dict):
        raise SystemExit(f"Metric {name} is missing from the k6 summary")
    values = metric.get("values") if isinstance(metric.get("values"), dict) else metric
    return values


def number(values: dict[str, Any], key: str) -> float:
    if key not in values or values[key] is None:
        raise SystemExit(f"Metric value {key} is missing")
    return float(values[key])


def fail_rate(summary: dict[str, Any]) -> float:
    values = metric_values(summary, "http_req_failed")
    for key in ("rate", "value"):
        if values.get(key) is not None:
            return float(values[key])
    passes = values.get("passes")
    fails = values.get("fails")
    if passes is not None and fails is not None:
        total = float(passes) + float(fails)
        return 0.0 if total == 0 else float(passes) / total
    raise SystemExit(
        "http_req_failed rate is missing "
        f"(keys: {sorted(str(key) for key in values)})"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--percent", type=float, default=20)
    parser.add_argument("--error-delta", type=float, default=0.02)
    args = parser.parse_args()

    with open(args.current, encoding="utf-8") as handle:
        current = json.load(handle)

    try:
        with open(args.baseline, encoding="utf-8") as handle:
            baseline = json.load(handle)
    except FileNotFoundError:
        print("No performance baseline found; current run will be recorded as the baseline")
        return 2

    current_p95 = number(metric_values(current, "http_req_duration"), "p(95)")
    baseline_p95 = number(metric_values(baseline, "http_req_duration"), "p(95)")
    current_p99 = number(metric_values(current, "http_req_duration"), "p(99)")
    baseline_p99 = number(metric_values(baseline, "http_req_duration"), "p(99)")
    current_fail = fail_rate(current)
    baseline_fail = fail_rate(baseline)

    limit = 1 + args.percent / 100
    failed = False

    print("Performance regression report")
    print(f"{'metric':<28} {'baseline':>12} {'current':>12} {'limit':>12} result")

    def row(label: str, base: float, cur: float, allowed: float, unit: str, worse: bool) -> None:
        nonlocal failed
        status = "FAIL" if worse else "PASS"
        if worse:
            failed = True
        print(f"{label:<28} {base:11.2f}{unit} {cur:11.2f}{unit} {allowed:11.2f}{unit} {status}")

    row(
        "http_req_duration p95",
        baseline_p95,
        current_p95,
        baseline_p95 * limit,
        "ms",
        current_p95 > baseline_p95 * limit,
    )
    row(
        "http_req_duration p99",
        baseline_p99,
        current_p99,
        baseline_p99 * limit,
        "ms",
        current_p99 > baseline_p99 * limit,
    )
    fail_limit = baseline_fail + args.error_delta
    row(
        "http_req_failed",
        baseline_fail * 100,
        current_fail * 100,
        fail_limit * 100,
        "%",
        current_fail > fail_limit,
    )

    if failed:
        print(
            f"Regression exceeds {args.percent:g}% latency or "
            f"{args.error_delta * 100:g}pp error-rate allowance; blocking production approval"
        )
        return 1

    print("No performance regression vs staging baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())

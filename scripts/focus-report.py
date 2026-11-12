#!/usr/bin/env python3
"""Report the local exact-focus metric for the alpha test.

Reads the JSONL written by FocusTelemetry. No titles or prompt text are
stored, so this is safe to run and share.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys

DEFAULT_PATH = os.path.expanduser(
    "~/Library/Application Support/Bantay-TUI/focus-log.jsonl"
)


def parse_timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--path", default=DEFAULT_PATH)
    args = parser.parse_args()

    try:
        with open(args.path, encoding="utf-8") as handle:
            events = [json.loads(line) for line in handle if line.strip()]
    except FileNotFoundError:
        print(f"no focus log yet: {args.path}")
        return 1
    except (OSError, json.JSONDecodeError) as error:
        print(f"could not read focus log: {error}")
        return 1

    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.days)
    recent = [
        event
        for event in events
        if parse_timestamp(event["timestamp"]) >= cutoff
    ]
    successes = sum(1 for event in recent if event.get("success") is True)
    rate = successes / len(recent) if recent else 0.0
    per_day = len(recent) / args.days

    methods: dict[str, dict[str, int]] = {}
    for event in recent:
        method = event.get("method", "unknown")
        bucket = methods.setdefault(method, {"total": 0, "successes": 0})
        bucket["total"] += 1
        if event.get("success") is True:
            bucket["successes"] += 1

    print(f"window_days={args.days}")
    print(f"clicks={len(recent)}")
    print(f"successes={successes}")
    print(f"success_rate={rate:.1%}")
    print(f"clicks_per_day={per_day:.1f}")
    for method, bucket in sorted(methods.items()):
        method_rate = bucket["successes"] / bucket["total"]
        print(
            f"method={method} clicks={bucket['total']} "
            f"success_rate={method_rate:.1%}"
        )

    target = rate >= 0.90 and len(recent) >= 40 and per_day >= 3
    print(f"target_met={str(target).lower()}")
    return 0 if target else 2


if __name__ == "__main__":
    sys.exit(main())

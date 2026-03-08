"""Usage: python cost.py [--today | --week | YYYY-MM-DD]"""

import json
import glob
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta

JSONL_PATH = os.path.expanduser("~/.config/onedot/log.jsonl")
JSONL_GLOB = os.path.expanduser("~/.config/onedot/log*.jsonl")

# Per 1M tokens: (input, output)
MODEL_PRICES = {
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-2.5-flash":      (0.30, 2.50),
    "gemini-2.5-pro":        (1.25, 10.00),
    "gemini-2.0-flash":      (0.10, 0.40),
}
DEFAULT_PRICE = MODEL_PRICES["gemini-2.5-flash-lite"]


def price_for(model):
    return MODEL_PRICES.get(model, DEFAULT_PRICE)


def main():
    paths = sorted(glob.glob(JSONL_GLOB))
    if not paths:
        print("No log file found.")
        return

    # Parse date filter
    after = None
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        today = datetime.now().date()
        if arg == "--today":
            after = datetime(today.year, today.month, today.day)
        elif arg == "--week":
            start = today - timedelta(days=today.weekday())
            after = datetime(start.year, start.month, start.day)
        else:
            try:
                after = datetime.fromisoformat(arg)
            except ValueError:
                print(f"Invalid date: {arg}")
                return

    daily = defaultdict(lambda: {"input": 0, "output": 0, "calls": 0, "idle": 0, "cost": 0.0})

    for path in paths:
        with open(path) as f:
            for line in f:
                try:
                    entry = json.loads(line)
                    ts = datetime.fromisoformat(entry["ts"])
                except (json.JSONDecodeError, KeyError, ValueError):
                    continue
                if after and ts < after:
                    continue
                day = ts.date().isoformat()
                if entry["event"] == "classify":
                    tokens = entry.get("tokens") or {}
                    inp = tokens.get("input", 0)
                    out = tokens.get("output", 0)
                    daily[day]["input"] += inp
                    daily[day]["output"] += out
                    daily[day]["calls"] += 1
                    ip, op = price_for(entry.get("model"))
                    daily[day]["cost"] += inp / 1e6 * ip + out / 1e6 * op
                elif entry["event"].startswith("idle"):
                    daily[day]["idle"] += 1

    if not daily:
        print("No entries found.")
        return

    total_in = total_out = total_calls = total_idle = total_cost = 0
    for day in sorted(daily):
        d = daily[day]
        total_in += d["input"]
        total_out += d["output"]
        total_calls += d["calls"]
        total_idle += d["idle"]
        total_cost += d["cost"]
        print(f"{day}  {d['calls']:4d} calls  {d['idle']:4d} idle  "
              f"{d['input']:>8,} in  {d['output']:>6,} out  ${d['cost']:.4f}")

    print("-" * 70)
    print(f"total   {total_calls:4d} calls  {total_idle:4d} idle  "
          f"{total_in:>8,} in  {total_out:>6,} out  ${total_cost:.4f}")


if __name__ == "__main__":
    main()

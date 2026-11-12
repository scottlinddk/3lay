#!/usr/bin/env python3
"""Summarize paired, measured device trials. Does not manufacture missing trial measurements."""
import argparse
import json
import math
import statistics


def summarize(trials):
    pairs = {}
    numeric = ("captureSeconds", "dimensionErrorMM", "holes", "peakMemoryMB", "adviceCount",
               "unsupportedAdviceCount", "inferenceMilliseconds")
    for trial in trials:
        condition = trial["condition"]
        if condition not in ("baseline", "coach"):
            raise ValueError("condition must be baseline or coach")
        pair = pairs.setdefault(trial["pair"], {})
        if condition in pair:
            raise ValueError(f"duplicate {condition} trial in {trial['pair']}")
        for field in ("success", "seriousThermal"):
            if not isinstance(trial[field], bool):
                raise ValueError(f"{field} must be boolean")
        for field in numeric:
            value = trial[field]
            if value is None and field == "dimensionErrorMM" and not trial["success"]:
                continue
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                raise ValueError(f"{field} must be a finite nonnegative number")
        if trial["unsupportedAdviceCount"] > trial["adviceCount"]:
            raise ValueError("unsupported advice count exceeds total advice")
        pair[condition] = trial
    complete = [p for p in pairs.values() if len(p) == 2]
    if not complete:
        raise ValueError("no complete baseline/coach pairs")
    result = {"completePairs": len(complete), "excludedIncompletePairs": len(pairs) - len(complete)}
    for condition in ("baseline", "coach"):
        rows = [p[condition] for p in complete]
        latency = sorted(t["inferenceMilliseconds"] for t in rows)
        result[condition] = {
            "successRate": statistics.mean(t["success"] for t in rows),
            "seriousThermalEvents": sum(t["seriousThermal"] for t in rows),
            "unsupportedAdviceCount": sum(t["unsupportedAdviceCount"] for t in rows),
            "p95InferenceMilliseconds": latency[math.ceil(0.95 * len(latency)) - 1],
        }
    result["medianPairedDeltaCoachMinusBaseline"] = {}
    for field in ("captureSeconds", "dimensionErrorMM", "holes", "peakMemoryMB"):
        eligible = [p for p in complete if field not in ("dimensionErrorMM", "holes")
                    or (p["coach"]["success"] and p["baseline"]["success"])]
        deltas = [p["coach"][field] - p["baseline"][field] for p in eligible]
        result["medianPairedDeltaCoachMinusBaseline"][field] = {
            "pairs": len(deltas), "delta": statistics.median(deltas) if deltas else None}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trials", help="JSON array of physical-device trials")
    args = parser.parse_args()
    try:
        with open(args.trials) as source:
            result = summarize(json.load(source))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

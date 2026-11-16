"""CI gate on Wake (Ackee Blockchain) detections.

Reads `.wake/detections.json` (written by `wake detect --export json all`) and `wake-triage.toml`. Fails on a High
detection that the triage file does not list, and on a triage entry that no longer matches any detection. Prints
every other detection so it stays visible in the log.

Wake is pinned with hashes in `.github/wake-requirements.txt`, so CI installs the same files even if new releases
stop. To change the version: `echo 'eth-wake==X.Y.Z' | uv pip compile - --generate-hashes --python-version 3.12
--python-platform x86_64-manylinux_2_28 --exclude-newer <two weeks ago> --no-header -o .github/wake-requirements.txt`.
"""

import json
import re
import sys
import tomllib
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def key(det: dict) -> tuple[str, str, str]:
    message = det["detection"]["message"]
    named = re.search(r"`([^`]+)`", message)
    return (
        det["detector_name"],
        det["detection"]["location"]["relative_path"],
        named.group(1) if named else message,
    )


def main() -> int:
    detections = [
        d for d in json.loads((ROOT / ".wake" / "detections.json").read_text()) if not d["suppressed"]
    ]
    triage = tomllib.loads((ROOT / "wake-triage.toml").read_text()).get("high", [])
    triaged = {(t["detector"], t["path"], t["function"]) for t in triage}

    high = [d for d in detections if d["impact"] == "high"]
    untriaged = [d for d in high if key(d) not in triaged]
    stale = triaged - {key(d) for d in high}

    for impact, confidence, name in sorted(
        Counter((d["impact"], d["confidence"], d["detector_name"]) for d in detections if d["impact"] != "high")
    ):
        print(f"visible: {impact} / {confidence} confidence: {name}")
    print(f"High: {len(high)} detections, {len(high) - len(untriaged)} triaged in wake-triage.toml")

    for d in untriaged:
        loc = d["detection"]["location"]
        print(
            f"::error file={loc['relative_path']},line={loc['start_line']}::"
            f"Wake {d['detector_name']} (high, {d['confidence']} confidence): {d['detection']['message']}"
        )
    for detector, path, function in sorted(stale):
        print(f"::error file=wake-triage.toml::stale entry, no detection matches: {detector} {path} {function}")

    return 1 if untriaged or stale else 0


if __name__ == "__main__":
    sys.exit(main())

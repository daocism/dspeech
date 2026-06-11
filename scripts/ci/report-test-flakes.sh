#!/usr/bin/env bash
set -euo pipefail

# Surfaces tests that only passed after a retry (`-retry-tests-on-failure`).
# Without this, retries silently convert flakes into green and real instability
# stays invisible. Reports every flaky/failed test to the CI step summary and
# fails the job when the flaky count exceeds FLAKE_THRESHOLD (default 0: zero
# tolerance, so the retry mechanism only DETECTS flakes, it never MASKS them).

bundle="${1:-}"
threshold="${FLAKE_THRESHOLD:-0}"

if [ -z "$bundle" ] || [ ! -d "$bundle" ]; then
  echo "report-test-flakes: result bundle not found: '${bundle}'" >&2
  exit 2
fi

xcresult_json() {
  local section="$1"
  local stderr_path
  stderr_path="$(mktemp)"
  if ! xcrun xcresulttool get test-results "$section" --path "$bundle" --format json 2>"$stderr_path"; then
    echo "report-test-flakes: xcresulttool failed reading ${section} from '${bundle}':" >&2
    sed 's/^/  /' "$stderr_path" >&2
    rm -f "$stderr_path"
    exit 2
  fi
  rm -f "$stderr_path"
}

summary_json="$(xcresult_json summary)"
tests_json="$(xcresult_json tests)"

FLAKE_THRESHOLD="$threshold" \
SUMMARY_JSON="$summary_json" \
TESTS_JSON="$tests_json" \
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}" \
python3 - <<'PY'
import json
import os
import sys

threshold = int(os.environ.get("FLAKE_THRESHOLD", "0"))
summary = json.loads(os.environ.get("SUMMARY_JSON") or "{}")
tests = json.loads(os.environ.get("TESTS_JSON") or "{}")

CLEAN = {"Passed", "Skipped", "Expected Failure"}


def walk(node, ancestry):
    out = []
    if isinstance(node, dict):
        nt = node.get("nodeType")
        name = node.get("name")
        path = ancestry + ([name] if name else [])
        if nt == "Test Case":
            children = node.get("children") or []
            child_results = [c.get("result") for c in children if isinstance(c, dict)]
            recovered = node.get("result") == "Passed" and any(
                r == "Failed" for r in child_results
            )
            failed = node.get("result") == "Failed"
            if recovered or failed:
                out.append(
                    {
                        "id": node.get("nodeIdentifier") or "/".join(path),
                        "name": " / ".join(path),
                        "result": node.get("result"),
                        "flaky": recovered,
                        "attempts": child_results,
                    }
                )
        for v in node.values():
            out.extend(walk(v, path))
    elif isinstance(node, list):
        for v in node:
            out.extend(walk(v, ancestry))
    return out


found = walk(tests, [])
flaky = [t for t in found if t["flaky"]]
hard_failed = [t for t in found if not t["flaky"]]

# Apple also aggregates retry insights into summary.statistics; surface them verbatim.
stats = [s for s in (summary.get("statistics") or []) if isinstance(s, dict)]

lines = []
lines.append("## Test flake report")
lines.append("")
lines.append(
    f"- total: {summary.get('totalTestCount', '?')} · "
    f"passed: {summary.get('passedTests', '?')} · "
    f"failed: {summary.get('failedTests', '?')} · "
    f"skipped: {summary.get('skippedTests', '?')} · "
    f"expected failures: {summary.get('expectedFailures', '?')}"
)
lines.append(f"- flaky (passed only after retry): **{len(flaky)}** (threshold {threshold})")
lines.append("")

if stats:
    lines.append("### xcresult statistics")
    for s in stats:
        title = s.get("title", "")
        subtitle = s.get("subtitle", "")
        lines.append(f"- {title} {subtitle}".rstrip())
    lines.append("")

if flaky:
    lines.append("### Flaky tests")
    for t in flaky:
        attempts = ", ".join(a or "?" for a in t["attempts"]) or "n/a"
        lines.append(f"- `{t['name']}` — attempts: {attempts}")
    lines.append("")

if hard_failed:
    lines.append("### Hard failures")
    for t in hard_failed:
        lines.append(f"- `{t['name']}` — {t['result']}")
    lines.append("")

report = "\n".join(lines)
print(report)
with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
    fh.write(report + "\n")

if len(flaky) > threshold:
    print(
        f"\n::error::{len(flaky)} flaky test(s) exceeded threshold {threshold}. "
        "Fix the source of the flake (do not raise the threshold to hide it).",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"\nNo flaky tests above threshold ({threshold}).")
PY

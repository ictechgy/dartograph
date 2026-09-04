#!/usr/bin/env bash
# analyzer 결합은 교체 가능한 index 어댑터 밖으로 새지 않아야 한다.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v rg >/dev/null 2>&1; then
  echo "Analyzer boundary scan failed: rg is not installed" >&2
  exit 2
fi

set +e
violations="$(rg -n "package:analyzer/" lib bin --glob '*.dart' --glob '!lib/src/index/**')"
scanner_status=$?
set -e

if [[ "$scanner_status" -gt 1 ]]; then
  echo "Analyzer boundary scan failed: rg exited $scanner_status" >&2
  exit 2
fi
if [[ -n "$violations" ]]; then
  echo "analyzer imports must remain inside lib/src/index:" >&2
  echo "$violations" >&2
  exit 1
fi

echo "Analyzer import boundary passed"

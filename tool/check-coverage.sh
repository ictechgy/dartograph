#!/usr/bin/env bash
# 제품 Dart 코드의 라인 커버리지가 90% 아래로 내려가면 실패한다.

set -euo pipefail

cd "$(dirname "$0")/.."

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/dartograph-coverage.XXXXXX")"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT
mkdir "$TEMPORARY_DIRECTORY/raw"

dart test --coverage="$TEMPORARY_DIRECTORY/raw"
dart run coverage:format_coverage \
  --packages=.dart_tool/package_config.json \
  --report-on=lib \
  --in="$TEMPORARY_DIRECTORY/raw" \
  --out="$TEMPORARY_DIRECTORY/lcov.info" \
  --lcov

read -r found hit < <(
  awk -F: '
    /^LF:/ { found += $2 }
    /^LH:/ { hit += $2 }
    END { print found + 0, hit + 0 }
  ' "$TEMPORARY_DIRECTORY/lcov.info"
)

if [[ "$found" -eq 0 ]]; then
  echo "Coverage failed: no executable lines found" >&2
  exit 1
fi

percentage="$(awk -v hit="$hit" -v found="$found" 'BEGIN { printf "%.2f", hit * 100 / found }')"
echo "Line coverage: $hit/$found ($percentage%)"

if ! awk -v hit="$hit" -v found="$found" 'BEGIN { exit !(hit * 100 >= found * 90) }'; then
  echo "Coverage failed: $percentage% is below 90%" >&2
  exit 1
fi

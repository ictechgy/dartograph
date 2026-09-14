#!/usr/bin/env bash
# 제품 Dart 코드의 라인 커버리지가 90% 아래로 내려가면 실패한다.

set -euo pipefail

cd "$(dirname "$0")/.."

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/dartograph-coverage.XXXXXX")"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT
mkdir -p "$TEMPORARY_DIRECTORY/raw/general" "$TEMPORARY_DIRECTORY/raw/activation"

# 설치된 wrapper의 반복 실행이 analyzer 테스트와 CPU를 경쟁하지 않게 한다.
# 두 단계 모두 통과해야 커버리지를 합산하며 전체 계약 항목을 한 번씩 검사한다.
dart test --exclude-tags=global_activation --coverage="$TEMPORARY_DIRECTORY/raw/general"
dart test --tags=global_activation --coverage="$TEMPORARY_DIRECTORY/raw/activation"
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

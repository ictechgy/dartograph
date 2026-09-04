#!/usr/bin/env bash
# 빌드된 실행 파일이 공개 종료 코드 계약을 지키는지 검증한다.

set -uo pipefail

cd "$(dirname "$0")/.."

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/dartograph-cli-contract.XXXXXX")"
trap 'rm -f "$TEMPORARY_DIRECTORY/dartograph"; rmdir "$TEMPORARY_DIRECTORY"' EXIT

BINARY="${1:-$TEMPORARY_DIRECTORY/dartograph}"
if [[ $# -eq 0 ]]; then
  dart compile exe bin/dartograph.dart -o "$BINARY" >/dev/null
fi

if [[ ! -x "$BINARY" ]]; then
  echo "Executable not found: $BINARY" >&2
  exit 2
fi

FAILURES=0

expect_status() {
  local expected="$1"
  local description="$2"
  shift 2

  "$BINARY" "$@" >/dev/null 2>&1
  local actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    printf '  ok    %-3s %s\n' "$actual" "$description"
  else
    printf '  FAIL  %-3s %s (expected %s)\n' "$actual" "$description" "$expected"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "CLI contract: $BINARY"
expect_status 0 "no arguments"
expect_status 0 "help" --help
expect_status 0 "short help" -h
expect_status 0 "version" --version
expect_status 1 "findings" dead --format json fixtures/false_positive_corpus
expect_status 0 "cycles report" cycles fixtures/phase5_contract
expect_status 1 "cycles strict findings" cycles --strict fixtures/phase5_contract
expect_status 1 "cycles trailing strict" cycles fixtures/phase5_contract --strict
expect_status 0 "rules report" rules --config fixtures/phase5_contract/layers.yaml fixtures/phase5_contract
expect_status 1 "rules strict findings" rules --config fixtures/phase5_contract/layers.yaml --strict fixtures/phase5_contract
expect_status 0 "metrics report" metrics fixtures/phase5_contract
expect_status 1 "metrics strict findings" metrics --strict fixtures/phase5_contract
expect_status 1 "metrics trailing strict" metrics fixtures/phase5_contract --strict
expect_status 2 "analysis failure" dead --format json fixtures/does-not-exist
expect_status 64 "usage error" no-such-command

if [[ "$FAILURES" -ne 0 ]]; then
  echo "CLI contract failed: $FAILURES case(s)" >&2
  exit 1
fi

echo "CLI contract passed"

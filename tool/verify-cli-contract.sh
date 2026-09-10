#!/usr/bin/env bash
# 빌드된 실행 파일이 공개 종료 코드 계약을 지키는지 검증한다.

set -uo pipefail

cd "$(dirname "$0")/.."

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/dartograph-cli-contract.XXXXXX")"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT

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
  expect_status 0 "cycles explain" cycles --explain project:lib/a.dart::a fixtures/phase5_contract
  expect_status 64 "cycles explain unknown" cycles --explain project:lib/missing.dart fixtures/phase5_contract
  expect_status 64 "cycles explain with strict" cycles --explain project:lib/a.dart::a --strict fixtures/phase5_contract
  expect_status 0 "rules explain" rules --config fixtures/phase5_contract/layers.yaml --explain project:lib/a.dart::a fixtures/phase5_contract
  expect_status 64 "rules explain unknown" rules --config fixtures/phase5_contract/layers.yaml --explain project:lib/missing.dart fixtures/phase5_contract
expect_status 0 "metrics report" metrics fixtures/phase5_contract
expect_status 1 "metrics strict findings" metrics --strict fixtures/phase5_contract
expect_status 1 "metrics trailing strict" metrics fixtures/phase5_contract --strict
expect_status 2 "analysis failure" dead --format json fixtures/does-not-exist
expect_status 64 "usage error" no-such-command
  expect_status 0 "batch query" query --batch fixtures/phase5_contract/query_batch.json fixtures/phase5_contract
  expect_status 64 "batch query partial miss" query --batch fixtures/phase5_contract/query_batch_missing.json fixtures/phase5_contract
  expect_status 0 "query depth" query a --depth 2 fixtures/phase5_contract
  expect_status 0 "query limit" query a --limit 1 fixtures/phase5_contract
  expect_status 64 "query depth below one" query a --depth 0 fixtures/phase5_contract
  expect_status 64 "query limit missing value" query a --limit fixtures/phase5_contract
expect_status 0 "graph comparison" compare fixtures/phase5_contract fixtures/phase5_contract
expect_status 2 "comparison failure" compare fixtures/does-not-exist fixtures/phase5_contract
expect_status 0 "affected report" affected HEAD fixtures/phase5_contract
expect_status 2 "affected index failure" affected HEAD fixtures/does-not-exist
expect_status 64 "affected missing root" affected HEAD
expect_status 64 "affected option-shaped ref" affected --strict fixtures/phase5_contract
expect_status 0 "graph dot" graph --format dot fixtures/phase5_contract
expect_status 0 "graph json" graph --format json fixtures/phase5_contract
expect_status 0 "graph mermaid" graph --format mermaid fixtures/phase5_contract
expect_status 0 "graph anon" graph --format anon fixtures/phase5_contract
expect_status 0 "graph html" graph --format html fixtures/phase5_contract
  expect_status 0 "graph level file" graph --format json --level file fixtures/phase5_contract
  expect_status 0 "graph level type" graph --format dot --level type fixtures/phase5_contract
  expect_status 0 "graph level html" graph --format html --level file fixtures/phase5_contract
  expect_status 0 "graph collapse" graph --format json --level file --collapse 1 fixtures/phase5_contract
  expect_status 64 "graph unknown level" graph --format json --level module fixtures/phase5_contract
  expect_status 64 "graph collapse without file level" graph --format json --collapse 1 fixtures/phase5_contract
  expect_status 64 "graph collapse below one" graph --format json --level file --collapse 0 fixtures/phase5_contract
  expect_status 64 "graph duplicate level" graph --format json --level file --level type fixtures/phase5_contract
expect_status 2 "graph failure" graph --format dot fixtures/does-not-exist
expect_status 0 "skill" skill
expect_status 0 "bridges" bridges --format json fixtures/phase5_contract
expect_status 2 "bridges failure" bridges --format json fixtures/does-not-exist
  expect_status 0 "bridges project override" bridges --format json --project fixtures fixtures/phase5_contract
  expect_status 64 "bridges project not containing root" bridges --format json --project fixtures/phase5_contract/lib fixtures/phase5_contract
  expect_status 64 "bridges duplicate project" bridges --format json --project fixtures --project fixtures fixtures/phase5_contract
  expect_status 64 "bridges project missing value" bridges --format json --project
  expect_status 0 "baseline write" baseline --write "$TEMPORARY_DIRECTORY/baseline.json" fixtures/phase5_contract
  expect_status 0 "dead with written baseline" dead --format json --baseline "$TEMPORARY_DIRECTORY/baseline.json" fixtures/phase5_contract
  expect_status 1 "dead test-only corpus has a dead declaration" dead --format json fixtures/test_only_corpus
  expect_status 0 "dead report-test-only is info" dead --report-test-only --format json fixtures/test_only_corpus
  expect_status 0 "dead report-test-only text" dead --report-test-only --format text fixtures/test_only_corpus
  expect_status 0 "dead redundant-public is info" dead --report-redundant-public --format json fixtures/test_only_corpus
  expect_status 64 "dead redundant-public with test-only" dead --report-redundant-public --report-test-only --format json fixtures/test_only_corpus
  expect_status 64 "dead report-test-only with explain" dead --report-test-only --explain project:lib/prod.dart::onlyReachedByTest --format json fixtures/test_only_corpus
  expect_status 64 "dead report-test-only with baseline" dead --report-test-only --baseline "$TEMPORARY_DIRECTORY/baseline.json" --format json fixtures/test_only_corpus
  INIT_DIR="$TEMPORARY_DIRECTORY/init-test"
  mkdir -p "$INIT_DIR"
  expect_status 0 "init" init "$INIT_DIR"
  expect_status 64 "init conflict without force" init "$INIT_DIR"
  expect_status 0 "init force overwrite" init --force "$INIT_DIR"
  expect_status 2 "init failure on non-existent directory" init "$TEMPORARY_DIRECTORY/does-not-exist"
  expect_status 2 "init failure on file target" init "$INIT_DIR/dartograph.yaml"
  expect_status 64 "init duplicate force" init --force --force "$INIT_DIR"
  expect_status 64 "init multiple positional arguments" init "$INIT_DIR" "$INIT_DIR"
  INIT_DEFAULT_DIR="$TEMPORARY_DIRECTORY/init-default"
  mkdir -p "$INIT_DEFAULT_DIR"
  pushd "$INIT_DEFAULT_DIR" >/dev/null
  expect_status 0 "init default directory" init
  popd >/dev/null

if [[ "$FAILURES" -ne 0 ]]; then
  echo "CLI contract failed: $FAILURES case(s)" >&2
  exit 1
fi

echo "CLI contract passed"

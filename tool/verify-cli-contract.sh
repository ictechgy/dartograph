#!/usr/bin/env bash
# 빌드된 실행 파일이 공개 종료 코드 계약을 지키는지 검증한다.
# 명령 출력은 전부 버린다 — 이 스크립트는 exit-code 계약만 검증하고
# 메시지 내용 계약은 test/cli/의 단위 테스트가 담당한다.

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
  expect_status 1 "dead markdown" dead --format markdown fixtures/phase5_contract
  expect_status 0 "dead test-only markdown" dead --report-test-only --format markdown fixtures/test_only_corpus
  CODEOWNERS_FILE="$TEMPORARY_DIRECTORY/CODEOWNERS"
  printf 'lib/ @lib-team\n' > "$CODEOWNERS_FILE"
  expect_status 1 "dead codeowners report" dead --format codeowners --codeowners "$CODEOWNERS_FILE" fixtures/test_only_corpus
  expect_status 64 "dead codeowners without file" dead --format codeowners fixtures/test_only_corpus
  expect_status 64 "codeowners option without codeowners format" dead --format json --codeowners "$CODEOWNERS_FILE" fixtures/test_only_corpus
  expect_status 2 "codeowners file missing" dead --format codeowners --codeowners "$TEMPORARY_DIRECTORY/absent" fixtures/test_only_corpus
  expect_status 0 "dead redundant-public is info" dead --report-redundant-public --format json fixtures/test_only_corpus
  expect_status 64 "dead redundant-public with test-only" dead --report-redundant-public --report-test-only --format json fixtures/test_only_corpus
  expect_status 64 "dead report-test-only with explain" dead --report-test-only --explain project:lib/prod.dart::onlyReachedByTest --format json fixtures/test_only_corpus
  expect_status 64 "dead report-test-only with baseline" dead --report-test-only --baseline "$TEMPORARY_DIRECTORY/baseline.json" --format json fixtures/test_only_corpus
  expect_status 1 "dead closed-app findings" dead --format json --closed-app fixtures/closed_app
  expect_status 0 "baseline write closed-app" baseline --write "$TEMPORARY_DIRECTORY/baseline-closed.json" --closed-app fixtures/closed_app
  expect_status 0 "dead closed-app with baseline" dead --format json --closed-app --baseline "$TEMPORARY_DIRECTORY/baseline-closed.json" fixtures/closed_app
  expect_status 64 "dead closed-app with redundant-public" dead --report-redundant-public --closed-app --format json fixtures/closed_app
  expect_status 1 "deps hygiene findings" deps --format json fixtures/dependency_audit
  expect_status 0 "deps clean manifest" deps fixtures/closed_app
  expect_status 64 "deps usage error" deps
  expect_status 64 "deps unknown format" deps --format xml fixtures/closed_app
  CHANGES_FILE="$TEMPORARY_DIRECTORY/changes.json"
  printf '["lib/a.dart"]' > "$CHANGES_FILE"
  expect_status 0 "impact changed" impact --changed "$CHANGES_FILE" --format json fixtures/phase5_contract
  expect_status 0 "impact changed text" impact --changed "$CHANGES_FILE" fixtures/phase5_contract
  expect_status 0 "impact changed markdown" impact --changed "$CHANGES_FILE" --format markdown fixtures/phase5_contract
  expect_status 0 "impact changed sarif" impact --changed "$CHANGES_FILE" --format sarif fixtures/phase5_contract
  expect_status 0 "impact changed github-actions" impact --changed "$CHANGES_FILE" --format github-actions fixtures/phase5_contract
  expect_status 0 "impact symbol" impact --symbol project:lib/a.dart::a --format json fixtures/phase5_contract
  expect_status 0 "impact since" impact --since HEAD --format json fixtures/phase5_contract
  expect_status 64 "impact no seed" impact fixtures/phase5_contract
  expect_status 64 "impact two seeds" impact --since HEAD --symbol project:lib/a.dart::a fixtures/phase5_contract
  expect_status 64 "impact unknown format" impact --since HEAD --format xml fixtures/phase5_contract
  expect_status 64 "impact unknown fail-on" impact --since HEAD --fail-on sometimes fixtures/phase5_contract
  expect_status 64 "impact duplicate since" impact --since A --since B fixtures/phase5_contract
  expect_status 64 "impact missing symbol" impact --symbol project:lib/missing.dart fixtures/phase5_contract
  expect_status 64 "impact zero depth" impact --since HEAD --depth 0 fixtures/phase5_contract
  expect_status 2 "impact failure" impact --changed "$CHANGES_FILE" fixtures/does-not-exist
  expect_status 0 "runtime report" runtime fixtures/runtime_corpus
  expect_status 0 "runtime text" runtime --format text fixtures/runtime_corpus
  expect_status 0 "runtime json" runtime --format json --verify fixtures/runtime_corpus
  expect_status 0 "runtime markdown" runtime --format markdown fixtures/runtime_corpus
  expect_status 0 "runtime github-actions" runtime --format github-actions fixtures/runtime_corpus
  expect_status 0 "runtime sarif" runtime --format sarif fixtures/runtime_corpus
  expect_status 0 "runtime detect only" runtime --no-verify fixtures/runtime_corpus
  expect_status 0 "runtime limit" runtime --limit 1 --format json fixtures/runtime_corpus
  expect_status 0 "runtime env override" runtime --env RUNTIME_CORPUS_TOKEN=present fixtures/runtime_corpus
  expect_status 0 "runtime dart-define override" runtime --dart-define RUNTIME_CORPUS_BASE_URL=https://example.com fixtures/runtime_corpus
  expect_status 0 "runtime fail-on none" runtime --fail-on none fixtures/runtime_corpus
  expect_status 0 "runtime execute entrypoint" runtime --execute bin/corpus_worker.dart fixtures/runtime_corpus
  EXECUTION_DIR="$TEMPORARY_DIRECTORY/runtime-execution"
  mkdir -p "$EXECUTION_DIR/bin"
  cat >"$EXECUTION_DIR/pubspec.yaml" <<'YAML'
name: runtime_execution_probe
environment:
  sdk: '>=3.11.0 <4.0.0'
YAML
  cat >"$EXECUTION_DIR/bin/main.dart" <<'DART'
import 'dart:io';
void main() => File('executed.txt').writeAsStringSync('executed');
DART
  expect_status 0 "runtime execute succeeds through installed binary" runtime --execute bin/main.dart --fail-on low "$EXECUTION_DIR"
  if [[ ! -f "$EXECUTION_DIR/executed.txt" ]] || [[ "$(cat "$EXECUTION_DIR/executed.txt")" != "executed" ]]; then
    echo "  FAIL  runtime entrypoint did not produce its execution witness"
    FAILURES=$((FAILURES + 1))
  fi
  expect_status 1 "runtime fail-on medium findings" runtime --fail-on medium fixtures/runtime_corpus
  expect_status 1 "runtime fail-on high findings" runtime --fail-on high fixtures/runtime_corpus
  expect_status 64 "runtime missing root" runtime
  expect_status 64 "runtime unknown format" runtime --format xml fixtures/runtime_corpus
  expect_status 64 "runtime unknown fail-on" runtime --fail-on sometimes fixtures/runtime_corpus
  expect_status 64 "runtime duplicate format" runtime --format json --format text fixtures/runtime_corpus
  expect_status 64 "runtime duplicate verify" runtime --verify --no-verify fixtures/runtime_corpus
  expect_status 64 "runtime duplicate fail-on" runtime --fail-on none --fail-on high fixtures/runtime_corpus
  expect_status 64 "runtime env missing value" runtime --env
  expect_status 64 "runtime env without equals" runtime --env RUNTIME_CORPUS_TOKEN fixtures/runtime_corpus
  expect_status 64 "runtime dart-define missing value" runtime --dart-define
  expect_status 64 "runtime empty definition key" runtime --dart-define =value fixtures/runtime_corpus
  expect_status 64 "runtime zero limit" runtime --limit 0 fixtures/runtime_corpus
  expect_status 64 "runtime execute missing value" runtime --execute
  expect_status 64 "runtime execute unknown entrypoint" runtime --execute bin/nope.dart fixtures/runtime_corpus
  expect_status 64 "runtime two roots" runtime fixtures/phase5_contract fixtures/runtime_corpus
  expect_status 2 "runtime failure" runtime --format json fixtures/does-not-exist
  LEDGER_DIR="$TEMPORARY_DIRECTORY/ledger"
  expect_status 0 "history missing ledger is empty" history --ledger "$LEDGER_DIR"
  expect_status 64 "history missing ledger option" history
  expect_status 64 "history unknown format" history --ledger "$LEDGER_DIR" --format sarif
  expect_status 1 "record a dead run" dead --format json --record "$LEDGER_DIR" fixtures/test_only_corpus
  expect_status 0 "record a graph run" graph --format json --record "$LEDGER_DIR" fixtures/phase5_contract
  expect_status 0 "history after record" history --ledger "$LEDGER_DIR"
  expect_status 0 "history commit filter" history --ledger "$LEDGER_DIR" --commit deadbeef
  expect_status 0 "history json" history --ledger "$LEDGER_DIR" --format json
  expect_status 64 "record missing option value" graph --format json --record --level file fixtures/phase5_contract
  expect_status 64 "record duplicate" dead --format json --record "$LEDGER_DIR" --record "$LEDGER_DIR" fixtures/phase5_contract
  expect_status 64 "record on non-recordable command" init --record "$LEDGER_DIR" "$TEMPORARY_DIRECTORY/init-record"
  expect_status 64 "mcp with arguments" mcp --help
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

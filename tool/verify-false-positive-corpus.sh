#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_corpus="$repo_root/fixtures/false_positive_corpus"
dart_bin=${DART:-dart}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/dartograph-corpus.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT
corpus="$temporary_directory/corpus"
cp -R "$source_corpus" "$corpus"
rm -rf "$corpus/.dart_tool"
rm -f "$corpus/pubspec.lock"

(cd "$corpus" && "$dart_bin" pub get --offline && "$dart_bin" analyze)
set +e
output=$(cd "$repo_root" && "$dart_bin" run dartograph dead --format json "$corpus")
status=$?
set -e
test "$status" -eq 1
finding_ids=$(printf '%s' "$output" | grep -o '"id":"[^"]*"')
printf '%s' "$finding_ids" | grep -q 'intentionallyDead'
printf '%s' "$finding_ids" | grep -q 'NotAnEntryPoint.main'
printf '%s' "$finding_ids" | grep -q 'falselyAnnotated'
printf '%s' "$finding_ids" | grep -q 'falsePragma'
printf '%s' "$finding_ids" | grep -q 'unused_file.dart'
# 미사용 연산자는 계속 보고돼야 한다(연산자도 양방향 검증). `*`·`~/`는
# 정규식 메타문자라 고정 문자열로 찾는다.
printf '%s' "$finding_ids" | grep -qF 'Vector.*'
printf '%s' "$finding_ids" | grep -qF 'Meters.~/'
# 쓰기(`w[0] = 7`)만 소비된 읽기 연산자는 계속 보고돼야 한다.
printf '%s' "$finding_ids" | grep -qF 'WriteOnly.[]'
# 보존 항목에도 연산자 ID(`+`·`unary-`·`-`)가 메타문자를 포함하므로 -F로 통일한다.
for preserved in keptForTesting nativeEntry CorpusPlugin CorpusPluginLinux CorpusWebPlugin devBootstrap routeFactory User MixedFeature Labelled Decoration copyUser TelemetryLevel 'Vector.+' 'Vector.unary-' 'Meters.-' 'WriteOnly.[]='; do
  if printf '%s' "$finding_ids" | grep -qF "$preserved"; then
    echo "preserved declaration reported: $preserved" >&2
    exit 1
  fi
done

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

(cd "$corpus" && "$dart_bin" pub get && "$dart_bin" analyze)
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
for preserved in keptForTesting nativeEntry CorpusPlugin CorpusPluginLinux CorpusWebPlugin devBootstrap routeFactory User MixedFeature Labelled Decoration copyUser; do
  if printf '%s' "$finding_ids" | grep -q "$preserved"; then
    echo "preserved declaration reported: $preserved" >&2
    exit 1
  fi
done

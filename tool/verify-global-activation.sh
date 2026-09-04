#!/usr/bin/env bash
# 격리된 pub cache에 path 설치한 공개 바이너리의 계약을 검증한다.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVATION_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dartograph-activation.XXXXXX")"
case "$ACTIVATION_ROOT" in
  "${TMPDIR:-/tmp}"/dartograph-activation.*) ;;
  *) echo "Unexpected activation directory" >&2; exit 2 ;;
esac
trap 'rm -rf "$ACTIVATION_ROOT"' EXIT

export PUB_CACHE="$ACTIVATION_ROOT/pub-cache"
dart "$REPOSITORY_ROOT/tool/copy_hosted_cache.dart" \
  "$REPOSITORY_ROOT/.dart_tool/package_config.json" "$PUB_CACHE"

PACKAGE_COPY="$ACTIVATION_ROOT/package"
mkdir -p "$PACKAGE_COPY"
cp "$REPOSITORY_ROOT/pubspec.yaml" "$PACKAGE_COPY/pubspec.yaml"
cp -R "$REPOSITORY_ROOT/bin" "$PACKAGE_COPY/bin"
cp -R "$REPOSITORY_ROOT/lib" "$PACKAGE_COPY/lib"
cd "$ACTIVATION_ROOT"
dart pub global activate --source path "$PACKAGE_COPY" >/dev/null

cd "$REPOSITORY_ROOT"
tool/verify-cli-contract.sh "$PUB_CACHE/bin/dartograph"
echo "Global activation contract passed"

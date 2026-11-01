#!/usr/bin/env bash
# analyzer 결합은 교체 가능한 index 어댑터 밖으로 새지 않아야 한다.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v git >/dev/null 2>&1; then
  echo "Analyzer boundary scan failed: git is not installed" >&2
  exit 2
fi

# git grep은 checkout에 이미 있는 git으로 추적·미추적 파일을 함께 훑고 .gitignore를
# 따른다. pathspec의 `*`는 `/`도 넘으므로 하위 디렉터리까지 포함한다. 일치 없음은
# 1, 저장소 밖 등 검사 실패는 128이다.
set +e
violations="$(git grep --untracked -n -e 'package:analyzer/' -- 'lib/*.dart' 'bin/*.dart' ':(exclude)lib/src/index/*')"
scanner_status=$?
set -e

if [[ "$scanner_status" -gt 1 ]]; then
  echo "Analyzer boundary scan failed: git grep exited $scanner_status" >&2
  exit 2
fi
if [[ -n "$violations" ]]; then
  echo "analyzer imports must remain inside lib/src/index:" >&2
  echo "$violations" >&2
  exit 1
fi

echo "Analyzer import boundary passed"

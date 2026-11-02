#!/usr/bin/env bash
# analyzer 결합은 교체 가능한 index 어댑터 밖으로 새지 않아야 한다.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v git >/dev/null 2>&1; then
  echo "Analyzer boundary scan failed: git is not installed" >&2
  exit 2
fi

# 사용자 환경의 pathspec 해석 변수는 아래 패턴의 뜻을 바꿔 위반을 놓치게 한다.
# 저장소 선택 변수(GIT_DIR 등)는 다른 저장소의 index·exclude로 이 checkout을 훑게
# 한다. 둘 다 지우고 스크립트가 있는 checkout을 git이 직접 찾게 한다.
unset GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_LITERAL_PATHSPECS GIT_ICASE_PATHSPECS \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

# 이 디렉터리가 저장소 최상위여야 한다. 자기 .git 없이 이 경로를 무시하는 상위
# 저장소 안에 있으면 git grep이 파일을 하나도 보지 않아 위반이 있어도 통과한다.
# 작업 트리 안이고 최상위에서 `--show-prefix`가 빈 문자열인지로 판정한다. 경로
# 문자열을 비교하지 않으므로 Git for Windows(`C:/…`)와 MSYS bash(`/c/…`)처럼 경로
# 표기가 달라도 같다.
set +e
inside="$(git rev-parse --is-inside-work-tree 2>/dev/null)"
inside_status=$?
prefix="$(git rev-parse --show-prefix 2>/dev/null)"
prefix_status=$?
set -e
if [[ "$inside_status" -ne 0 || "$inside" != true ||
  "$prefix_status" -ne 0 || -n "$prefix" ]]; then
  echo "Analyzer boundary scan failed: $(pwd -P) is not the top level of a Git work tree" >&2
  exit 2
fi

# git grep은 checkout에 이미 있는 git으로 추적·미추적 파일을 함께 훑고 .gitignore를
# 따른다. `:(glob)`의 `**/`는 0개 이상의 디렉터리다. 일치 없음은 1, 검사 실패는
# 128이다.
set +e
violations="$(git grep --untracked -n -e 'package:analyzer/' -- ':(glob)lib/**/*.dart' ':(glob)bin/**/*.dart' ':(glob,exclude)lib/src/index/**')"
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

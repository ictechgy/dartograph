# CLAUDE.md

Claude Code로 이 저장소에서 작업할 때의 안내입니다.

**작업 규칙의 정본은 [AGENTS.md](AGENTS.md)입니다. 먼저 읽으세요.**
이 파일은 Claude Code에서만 의미가 있는 내용만 담습니다.

**세션을 이어받는다면 [HANDOFF.md](HANDOFF.md)부터 읽으세요.**

---

## 세션을 시작할 때

`git status --short --branch`로 브랜치와 작업 트리를 확인하세요. `main`에서는 작업하지 않습니다.

Dart SDK가 없으면 `asdf`나 `fvm`으로 설치합니다. 저장소 루트에 SDK 다운로드 디렉터리(`asdf-dart.*`)가 남아 있으면 다른 세션의 설치 잔재입니다 — 커밋하지 말고, 지우기 전에 그 세션이 끝났는지 확인하세요.

## 출력을 읽을 때 주의할 점

Bash 도구의 셸은 zsh입니다. `$cmd`는 워드 분할이 되지 않습니다(`${=cmd}`). 백그라운드 대기 루프에 `pgrep -f`를 쓰면 자기 자신을 잡습니다 — 산출물 파일을 기다리세요. macOS에는 `timeout`이 없습니다.

`dart test`는 실패를 `✗`와 `Some tests failed.`로 알립니다. 마지막 줄만 보지 말고 `grep -E "✗|Some tests failed|All tests passed"`로 확인하세요.

## GLM 리뷰를 받을 때

`../kartograph/CLAUDE.md`의 같은 절과 동일합니다 — 스크래치 git 저장소에 파일을 복사해 `review --files`로, `research` 모드 대신 질문 파일을 첨부한 `review` 모드로.

# Handoff

_Last updated: 2026-10-11_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다. 과거 Next Steps·미릴리스 표기는 당시 기록이다.

## Current Status

- **0.16.2 릴리스 준비**다. 기준 구현 커밋은 `3e521a573d7764bd12331d6a56980ae0e74cfdf6`이며,
  MCP 프레이밍 무결성과 analyzer 14.5 재검증을 포함한다. pub.dev·태그·GitHub Release를
  아직 발행하지 않았다. 2026-10-11 pub.dev API 조회 기준 최신은 0.16.1이고 0.16.2는 없다.
- 기준 구현의 Dart 3.13.3 일반 테스트 782개·격리 설치 테스트 1개·native CLI 계약 218개,
  제품 라인 커버리지 91.78%를 확인했다. Dart 3.11.0은 analyze·관련 테스트 51개만 검증했다.
  이후 기준 구현 PR146의 [CI](https://github.com/ictechgy/dartograph/actions/runs/38158056797)는
  Dart 3.11.0·3.13.3 두 전체 검증 작업 모두 통과했다. 실제 Flutter 코퍼스는 다시 실행하지 않았다.
  상세 로컬 검증 범위는 `doc/DECISION-analyzer.md`에 있다.
- 릴리스 브랜치는 버전·문서·버전 assertion만 변경한다. 기능 PR 병합 뒤 병합 커밋에
  릴리스 변경을 다시 적용하고, 그 최종 커밋의 CI·버전 계약·publish dry-run을 확인한다.
- 게시 순서는 CONTRIBUTING의 기존 절차를 유지한다: 게시 권한이 있는 환경에서
  `dart pub publish` 성공을 확인한 뒤 같은 커밋에 `v0.16.2` 태그와 GitHub Release를
  연결하고, 공개 패키지를 새 캐시에 설치해 `--version`을 확인한다. 기존 버전을 덮어쓰지 않는다.
- 현재 준비 환경에서는 게시에 쓸 인증 경로가 확인되지 않아 pub.dev 게시·태그·Release
  작업은 진행하지 않았다. 새 자격 증명이나 자동 게시 워크플로도 만들지 않았다.

## Earlier Verified Status

아래 0.15.0 기록은 과거 발행 근거다. 현재 릴리스 준비나 최신 레지스트리 버전으로 읽지 않는다.

- 자매 후속의 timestamp 계약을 [GRAPH-EXCHANGE](doc/GRAPH-EXCHANGE.md)에 반영했다.
  generatedAt은 문서 추출 시각이며 optional sourceModifiedAt은 별도 source mtime이다.
  dartograph는 mtime을 측정하지 않아 생략하며 기존 추출 시각 구현을 유지한다.
  이번 변경은 문서만이고 새 CLI·확장 버전을 발행하지 않았다.
- isthmus의 [실제 Flutter3.47.2 macOS·Android 앱 검사와 공개 RN 컴파일 retention](https://github.com/ictechgy/isthmus/blob/main/experiments/real-corpus/README.md)은
  자매 개발 소스의 별도 검증이다. dartograph의 RN 생산자 지원을 추가했다는 뜻은 아니다.

- dartograph **0.15.0**은 [pub.dev](https://pub.dev/packages/dartograph/versions/0.15.0)와
  [GitHub](https://github.com/ictechgy/dartograph/releases/tag/v0.15.0)에 발행됐다.
  릴리스 [PR #129](https://github.com/ictechgy/dartograph/pull/129)와 tag `v0.15.0`의 소스는 `b124839`다.
- archive SHA256 `4fc7a7958d2af6652ca7532fea3c73366ec16269d7783596d491a53f8170e38c`를 registry와 대조했고,
  별도 PUB_CACHE activation·CLI 버전을 확인했다. 릴리스 검사에는 format/analyze,
  coverage 90.71%, corpus·analyzer 경계·CLI 계약·publish dry-run 경고 0이 포함됐다.
- 0.14.0 이후 workspace·MCP 통합·setup·query source·보고 형식·test-list·브리지 계약 누적분은
  모두 0.15.0에 포함된다. PR #119~#124·#127의 옛 미커밋/미발행 표기를 현재 작업으로 읽지 않는다.
- RN v2 전역 이벤트·필수 컴파일러 ID·원본 caller 유지의 자매 계약은
  [GRAPH-EXCHANGE](doc/GRAPH-EXCHANGE.md)에 있다. dartograph가 RN JS·네이티브 소스를 추출한다는 뜻은 아니다.
  자매 발행/왕복 검증은 [isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md)를 따른다.
- `HANDOFF-PROGRESS.md`와 `editors/vscode/icon-drafts/`는 기존 사용자 미추적 파일이다.
  VS Code/analysis plugin은 이번 CLI 릴리스로 재발행하지 않았다.

## Next Steps

우선 0.16.2의 최종 병합 커밋 검증과 승인된 게시 경로를 확보한다. 아래 항목은 이전 후속 후보이며 이번 릴리스의 선행 조건이 아니다.

- pub.dev verified publisher 설정과 README 데모(asciinema).
- VS Code 확장 아이콘 선택. 기존 시안과 사용자 결정을 보존한다.
- adoption 대조 실험의 모델·과제 확대, 변경 범위 질의/설치 표면 정리는 필요할 때 범위를 선택한다.
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화를 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. 0.16.2는 릴리스 준비이며
게시됐다고 가정하지 마. 기능 PR 병합 뒤 릴리스 변경을 최종 커밋에 적용하고 CI·버전 계약·
publish dry-run을 확인해야 해. 게시 인증 경로가 준비되면 CONTRIBUTING의 순서대로 pub.dev,
같은 커밋의 태그·GitHub Release, 새 캐시 공개 설치 검증을 진행해. 과거 검증 범위를 확대해서
표현하지 말고 기존 사용자 파일과 분석 한계를 보존해.

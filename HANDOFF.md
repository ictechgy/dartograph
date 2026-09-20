# Handoff

_Last updated: 2026-09-20_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다. 과거 Next Steps·미릴리스 표기는 당시 기록이다.

## Current Status

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

요청됐던 CLI 구현·머지·0.15.0 발행은 완료됐다. 다음은 별도 후속 후보다.

- pub.dev verified publisher 설정과 README 데모(asciinema).
- VS Code 확장 아이콘 선택. 기존 시안과 사용자 결정을 보존한다.
- adoption 대조 실험의 모델·과제 확대, 변경 범위 질의/설치 표면 정리는 필요할 때 범위를 선택한다.
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화를 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. dartograph 0.15.0의
pub.dev·GitHub 발행과 독립 설치 검증은 완료됐어. HANDOFF-HISTORY.md의 옛 미커밋·미릴리스·
Next Steps를 현재 지시로 되살리지 마. HANDOFF-PROGRESS.md와 icon-drafts는 사용자 파일이야.
최신 요청에 맞는 작업만 진행하고, 기존 검사 근거와 분석 한계를 유지해.

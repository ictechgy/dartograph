# Handoff

_Last updated: 2026-09-06 by Codex (PR #7 기준으로 갱신)_

## Goal

- 영구 무료 MIT Dart/Flutter 근거 질의 CLI를 유지한다.
- 사용자가 요청한 근거 워크플로 구현·GLM 리뷰·머지·0.2.0 배포와 AGENTS 정리를 완료했다.
- 이번 작업은 이 인수인계 문서 갱신이다. 새 제품 기능이나 추가 배포 요청은 없다.

## Current Status

- 제품 기준: `v0.2.0` → `08fb197` (PR #5 merge).
- pub.dev `dartograph 0.2.0` 및 GitHub Release `v0.2.0` 공개 완료.
- 지침 기준: `c4d121d` (PR #7 merge). Astra 공식 가이드에 맞춘 지침·skill·CI 최적화와
  `doc/AGENT-WORKFLOW-AUDIT.md`가 반영됐다. 문서 작업 시작 시 main과 작업 트리는 깨끗했다.
- 이 문서는 `c4d121d`에서 만든 `docs/handoff-0.2.0-current` 브랜치에서 갱신한다.
  0.2.0 갱신 원본은 미머지 `docs/handoff-020`(`ce5ec23`)이며 그 내용을 보존해 가져왔다.
- 정본은 루트 AGENTS.md이며 CLAUDE.md는 이를 참조한다. 하위 규칙은 lib, lib/src/index,
  test, fixtures, tool, doc에 있다. 적용 범위는 링크가 아니라 디렉터리 위치로 결정된다.
- 제품 배포 blocker는 없다. HANDOFF 내용이 Git 상태보다 우선하지 않으므로 재개 시 실제 상태를 확인한다.

## Completed

- `query --batch <requests.json> [--baseline <file>] <root>`: 색인·도달성·이웃·baseline 공유.
  1–1000개 문자열, 최대 1 MiB. 순서·중복을 보존하며 미발견이 하나라도 있으면 전체 64,
  개별 결과는 모두 반환한다.
- `compare <before-root> <after-root>`: 준비된 두 checkout의 정점·간선·루트 차이와
  미도달 전환의 이전 경로·member witness를 출력한다. checkout/의존성 설치는 수행하지 않는다.
- finding에 소스별 분석 오류·미해석 호출·조건부 구성 한계를 연결하고 전역 영향 경고를 유지한다.
- bridge fact에 지원되는 Dart 선언의 어휘적 qualifiedName을 추가했다.
  생성자·extension 등 이름 귀속 미지원 호출은 위치와 missing-caller-symbols 한계를 남긴다.
- 호출 제거/복원·이름 변경 변형 회귀, batch 벤치마크, isthmus 합성 왕복 도구를 추가했다.
- 0.1.1의 provenance·scope·UTF-8 위치·UTC 밀리초·중첩 캐시·protobuf·CLI 오류 보강은 유지된다.

## Key Files & State

- `lib/src/analysis/symbol_query.dart`: 단일 query와 재사용 SymbolQuerySession.
- `lib/src/analysis/graph_comparison.dart`: 관측된 그래프 전후 차이와 근거.
- `lib/src/analysis/reachability_analyzer.dart`: dead/explain, known·witness, 소스별 한계.
- `lib/src/index/analyzer_graph_index.dart`: analyzer 어댑터·소스 진단·중첩 의존성 캐시.
- `lib/src/index/bridge_index.dart`: Flutter provenance·scope·Dart 선언 이름·bridge facts.
- `lib/src/cli/dartograph_cli.dart`: 입력 검증·batch/compare·0/1/2/64 계약.
- `test/index/evidence_mutation_test.dart`, `test/analysis/evidence_workflow_test.dart`:
  변형 불변성·root 손실·member witness의 주요 회귀.
- `test/cli/batch_query_test.dart`, `test/cli/graph_compare_test.dart`: 새 CLI 동작.
- `tool/benchmark_query.dart`, `tool/verify_bridge_query.dart`: 성능 동등성·isthmus 왕복.
- `doc/USAGE.md`: 실제 명령과 알려진 한계. `CHANGELOG.md`: 0.2.0 릴리스 내역.

## Important Context / Decisions

- Facts:
  - cache identity는 `dartograph-analysis-$toolVersion-cache-v2-source-evidence`다.
    추출 의미 변경 시 revision을 갱신한다. 내용 해시와 입력 변경 검사를 유지한다.
  - 소스 한계는 파일 수준 관측이다. 다른 파일의 동적 호출도 영향을 줄 수 있으며 한계 없음은 안전성 보증이 아니다.
  - compare는 인과 증명이나 삭제 판정이 아니다. rename은 삭제/추가로 보이며 matched SDK·의존성·설정은 호출자가 준비한다.
  - bridge의 qualifiedName은 어휘적 이름이다. Dart 컴파일러 USR을 발명하지 않는다.
  - isthmus가 언어 간 조인을 소유한다. 동적/미귀속/복수 후보를 임의로 확정하지 않는다.
  - 직접 Flutter services import만 provenance로 인정한다. re-export·Event/Basic 채널 등은 기존 limitation 계약을 따른다.
- Assumptions:
  - isthmus 왕복은 로컬에 준비된 소비자를 사용했다. 새 환경에서 설치 경로·버전을 확인해야 한다.
  - HANDOFF의 검증 수치는 아래 명시한 작업의 기록이며 이후 변경까지 보증하지 않는다.

## Verification

- 0.2.0 기능 검증: format·analyze 통과, 전체 116개 테스트, 라인 커버리지 92.47%.
- 오탐 코퍼스·analyzer 경계·확장된 컴파일 CLI 계약·격리 path 활성화 통과.
- GLM 기능 리뷰와 후속 리뷰의 실제 지적을 재현·수정했고 최종 차단 이슈 없음.
- PR #5의 최종 버전 커밋 `67e0589`: Dart 3.11.0/3.13.3 CI 통과 후 머지.
- 0.2.0 dry-run: 58 KB, 경고 0. 공개 pub.dev 패키지의 새 격리 설치와 전체 CLI 계약 통과.
- `dart run tool/benchmark_query.dart`: 합성 2,000노드/100질의, 약 227ms → 8ms,
  JSON 결과 동등. 실제 프로젝트 SLA나 독립 성능 평가가 아니다.
- `dart run tool/verify_bridge_query.dart <isthmus-main.js>`: 실제 Dart 추출+합성 Swift fact로
  선언 이름과 양쪽 위치 보존 확인. Swift 컴파일러/실제 앱 검증을 대체하지 않는다.
- PR #6 지침 문서: GLM blocker 없음, 링크·범위 감사 통과, Dart 3.11.0/3.13.3 CI 성공.
- PR #7 Astra 지침·skill·CI 최적화: GLM blocker 없음, CI 경로 중복 제거(테스트 2→1, 격리 활성화 3→1),
  Dart 3.11.0/3.13.3 CI 성공. 이번 handoff 갱신은 문서만 바꾸므로 제품 테스트를 재실행하지 않았다.
- 이번 handoff 시작 시 pub.dev 최신 0.2.0, 공개 Release, PR #6 merge 상태를 다시 조회했다.
  제품 테스트는 문서만 갱신하므로 재실행하지 않았다.

## Blockers & Open Questions

- 필수 제품 작업 없음. handoff 브랜치가 main에 반영됐는지는 다음 세션에서 확인한다.
- 선택 과제: 실제 사용자 작업의 정확성·반복 사용 평가, Pigeon/re-export 지원. 새 요구가 있을 때 범위를 정한다.
- 검토 후 의도적으로 보류한 항목(간과가 아님):
  - `package:args` 전환 — 수제 파싱은 "순수 Dart·최소 의존·결정적" 의도된 설계. 전면 교체는 CLI 계약과 다수 테스트 재작성을 요구한다.
  - isolate 병렬화로 cold-run 30초 SLA 달성 — `doc/DECISION-analyzer.md`의 311k LoC cold 35.9초가 목표 초과. 30초 검증에 대형 실제 Flutter 체크아웃이 필요하며 측정 없는 최적화는 금지된다.
  - melos 멀티패키지 — 대형 신규 기능. PRD v0.2+ 범위로 유지한다.
  - EventChannel·BasicMessageChannel fact화 — isthmus와 GRAPH-EXCHANGE 시맨틱 조율 없이 fact kind를 바꾸지 않는다. 현재는 limitation으로만 센다.
- 무료·JSON·MCP만으로 해자가 입증되지는 않았다. 코퍼스도 MIT fork가 복사할 수 있다.
  사용자 피드백 유입·회귀 대응·외부 계약 채택은 검증할 전략 가설이다.

## What Worked / Avoid

- GLM 제안은 실제 코드·테스트로 검증한다. GraphSnapshot이 이미 보장하는 endpoint·정렬을 놓친 지적은 기각했다.
- 대상 fixture 소스를 런타임으로 실행하지 않고 analyzer로 변형 결과를 검사했다.
- 다른 세션이 브랜치나 파일을 바꿀 수 있다. stage·merge·publish 직전에 상태와 커밋을 확인한다.
- 전역 pub wrapper도 dart를 PATH에서 찾는다. 로컬 실행은 `mise exec dart@3.13.3 -- <command>`를 사용할 수 있다.
- Markdown에 dart format을 실행하지 않는다. 반복 테스트는 새 변경·실패가 있을 때만 한다.
- pub.dev 업로드 성공 직후 설치 목록 전파가 지연될 수 있다. 동일 버전을 재게시하지 말고 새 격리 캐시로 설치를 재시도한다.
- .dart_tool·루트 pubspec.lock·테스트가 만든 사용자 캐시는 정리했다. 테스트 전 `dart pub get`이 필요하다.

## Next Steps

1. 실제 branch/status/log를 확인하고 루트 및 작업 경로의 AGENTS.md를 읽는다.
2. 이 handoff 문서의 main 반영 여부를 확인한다. 제품 재배포는 필요하지 않다.
3. 새 사용자 요청이 없다면 완료된 0.2.0 구현·배포를 반복하지 않는다.

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/dartograph`, read `HANDOFF.md` and applicable
`AGENTS.md` files, then continue from: `Verify current Git state and whether the handoff branch
is merged. Product 0.2.0 and agent-guidance PR #6·#7 are complete; follow the next explicit user task.`

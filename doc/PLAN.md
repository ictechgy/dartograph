# dartograph 계획

세 자매 중 가장 싸다. Phase 0 이 짧다.

## Phase 0 — 원천 검증 (반 세션)

원천이 정해져 있으므로(`package:analyzer`) 실험이 아니라 **확인**이다.

### 0.1 도그푸딩 대상 확보

바탕화면에 Flutter 프로젝트가 **없다** (2026-09-04 `pubspec.yaml` 스캔 결과 0). 공개 프로젝트를 클론한다.

| 저장소 | 이유 |
|---|---|
| `flutter/samples`의 `navigation_and_routing` | 작은 실제 앱과 `go_router` |
| `flutter/packages`의 `path_provider_platform_interface`·`path_provider_foundation` | **MethodChannel**, 조건부 export, 생성 FFI |
| `invoiceninja/flutter` | 생성 코드 제외 311k LoC, json_serializable/freezed/go_router 사용 |

### 0.2 analyzer 스크립트

- `AnalysisContextCollection` 으로 `flutter/samples` 의 앱 하나를 열고, 정상 분석 파일과 제외된 생성 파일의 resolved unit 을 순회하며 선언 수 · 참조 수 · 실행 시간을 출력하는 실험 스크립트
- 확인할 것: `Element` 의 안정 식별자(라이브러리 URI + 이름 경로)가 정점 ID 로 충분한가 · `part` 파일이 어느 라이브러리로 귀속되는가 · 생성 파일(`.g.dart`) 구분법 · 조건부 import 처리 · 실행 시간이 캐시 없이 견딜 만한가
- `analyzer` 14.x 의 API 가 예제 코드와 얼마나 다른지 — "자주 바뀐다"는 주장의 실측

### 0.3 결과

`doc/DECISION-analyzer.md` — 정점 ID 규칙, 생성 코드 판별 규칙, 캐시 필요 여부(측정값), 고정할 `analyzer` 버전.

## Phase 1 — 골격 (2 세션)

- Dart 패키지 하나, `lib/src/` 아래 `core/`(모델 · 그래프 · 설정), `index/`(analyzer 어댑터 — **analyzer 를 import 하는 유일한 곳**), `analysis/`, `export/`, `cli/`. `AGENTS.md` 에 왜 이렇게 나눴는지
- `CodeGraph` · `GraphNode` · `GraphEdge` · `EdgeKind.impliesUsage`. 도달성과 `query` 가 같은 술어를 쓰는 구조
- 종료 코드 계약 + `tool/verify-cli-contract.sh` 첫 커밋
- 커버리지 게이트(`package:coverage` + 스크립트, 라인 90%) CI 첫 주
- `graph` 가 `flutter/samples` 앱에서 DOT 를 낸다 — Phase 1 끝

## Phase 2 — 보존 규칙과 `dead` (2~3 세션)

- **오탐 코퍼스 먼저.** `fixtures/false_positive_corpus/` 는 실제로 `dart analyze` 가 통과하는 Flutter 패키지. 케이스: 다중 `main`, `@visibleForTesting`, json_serializable/freezed 참조, `@pragma('vm:entry-point')`, 라우트 테이블, 플러그인 `pubspec` 참조, 확장 메서드, 믹스인, `part`
- `ReachabilityAnalyzer` + `dead --explain`. 파일 레벨 미사용(어디서도 import/part 되지 않는 `lib/` 파일)도 여기서
- 세 도그푸딩 대상에서 상위 10 건 손 검증. 새 오탐은 코퍼스에 먼저

## Phase 3 — 도입 경로 (1~2 세션)

- 베이스라인, `--since`(cartograph `ChangedFiles` 의 함정 목록 참고), 리포트 형식, `pub global activate` 배포 검증

## Phase 4 — 에이전트 표면 + 브리지 (1~2 세션)

- `query` — cartograph 스키마 그대로. `limitations` 의 Dart 고유 항목: 조건부 import 단일 구성, 라우트 테이블 없는 문자열 라우트 수, 생성 코드 미갱신(`build_runner` 산출물이 소스보다 오래됨)
- `skill` — cartograph 스킬을 출발점으로 삼고, 여러 `main` 중 실제 build target을 확인하되 나머지도 보수적 루트임을 알린다
- `bridges --format json` — MethodChannel 생성·호출 사실과 EventChannel·BasicMessageChannel 미해석 limitation. 형식은 `../isthmus/docs/GRAPH-EXCHANGE.md`

## Phase 5 — 순환 · 규칙 · 지표 · 릴리스

- `cycles`, `rules`, `metrics`
- 릴리스: 태그 → pub.dev 발행 + GitHub Release. 발행 전 `pub global activate` 로 설치한 바이너리로 CLI 계약 재검증
- 0.1.0
- 0.1.1 — isthmus bridge 생산 계약과 explain·캐시·CLI 경계를 보강한 patch release

## 세션 운영

cartograph의 같은 절과 동일. 한 세션 한 Phase 일부, PR마다 GLM 리뷰, 오탐은 전부 코퍼스로.

## 진행 표

| Phase | 상태 | 비고 |
|---|---|---|
| 0 원천 검증 | 완료 | [`DECISION-analyzer.md`](DECISION-analyzer.md) |
| 1 골격 | 완료 | 실제 Flutter 샘플에서 결정적 graph 출력 |
| 2 보존 규칙 · dead | 완료 | 실제 meta·pragma·plugin 반례 코퍼스 |
| 3 도입 경로 | 완료 | 결정적 baseline, NUL 안전 `--since`, 4종 리포터, 격리 설치 검증 |
| 4 에이전트 표면 · bridges | 완료 | query·skill과 isthmus GRAPH-EXCHANGE v1 조인 검증 |
| 5 순환 · 규칙 · 지표 | 완료 | 반복형 Tarjan, YAML 규칙, 라이브러리별 Martin 지표 |
| v0.1.0 릴리스 | 완료 | pub.dev·GitHub Release 공개, 격리 설치, 3개 Flutter 패키지, self findings 0 |
| v0.1.1 bridge 계약 보강 | 완료 | provenance·scope·UTF-8·밀리초·미해석 limitation과 공개 plugin 왕복 |

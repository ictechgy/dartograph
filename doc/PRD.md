# dartograph PRD

## 한 줄

Dart/Flutter 코드베이스의 의존성 그래프를 공식 분석기로 만들고, 그 위에서 미사용 코드 · 파일 · 순환 · 레이어 규칙 · 지표를 근거와 함께 답하는, **영구 무료** CLI.

## 문제

- **DCM(구 dart_code_metrics)** 이 미사용 코드 · 파일 검사를 갖고 있지만 2023 년 유료 전환했다. 무료 티어는 **1인, 50k LoC 이하** (dcm.dev/pricing, 2026-09-04 확인). 팀이거나 프로젝트가 크면 유료다
- **`dart analyze`** 의 `unused_element` · `unused_import` 는 라이브러리 · 파일 단위의 지역 판정이다. "이 public 클래스를 프로젝트 어디서도 안 쓴다" 는 못 말한다
- 순환 의존(`lakos` 등 그래프 도구가 있으나 판정 · 근거 없음), 레이어 규칙, 아키텍처 지표를 한 곳에서 주는 도구가 없다

빈자리는 GLM 이 말한 것보다 좁다 — DCM 무료 티어가 개인 · 소규모는 덮는다. 그러나 **팀과 큰 프로젝트, 그리고 "라이선스 키 없이 CI 에 넣을 수 있는 도구"** 라는 자리는 비어 있다.

## 사용자

1. **CI 를 가진 Flutter 팀** — 라이선스 키 관리 없이 `--since origin/main --strict`
2. **50k LoC 를 넘긴 프로젝트** — DCM 무료 티어 밖
3. **코딩 에이전트** — 삭제 전에 `query` 로 묻고 `limitations` 와 `reason` 을 읽는다

## 영구 무료 약속

이 절은 PRD 의 일부이고 삭제하지 않는다.

- 라이선스는 MIT 이고 바꾸지 않는다
- 유료 티어 · 라이선스 키 · 좌석 수 · LoC 제한 · 텔레메트리 · 계정 로그인은 **영원히 없다**
- README 첫 화면에 위 두 줄을 적는다
- 이유: Periphery 와 DCM 이 각각 상업화되며 생긴 자리를 채우는 것이 이 프로젝트 군의 존재 이유다. 같은 길을 가면 존재 이유가 없다

## 범위

### 반드시 (v0.1)

- 심볼 그래프: 클래스 · 믹스인 · 확장 · 최상위 함수 · 메서드 · 필드 · 열거형 값. 참조 종류(call · reference · inheritance · implements · mixin · override · member · import)
- 파일 그래프: 라이브러리(import/export/part) 단위. **미사용 파일** 은 Dart 에서 특히 흔하다(옮겨 놓고 잊은 위젯)
- `dead` — 보존 루트에서 도달 불가한 선언과 파일, `--explain`
- `cycles` — Tarjan SCC + 끊을 후보. Dart 의 순환 import 는 합법이라 더 흔하다
- `rules` — 레이어 YAML의 allow/deny 위반과 직접 근거
- `metrics` — 라이브러리별 Ca · Ce · 불안정도 · 추상도 · 주계열 거리
- `graph` — DOT · Mermaid · JSON
- `query <symbol>` — cartograph 의 `SymbolQueryDocument` 와 **같은 스키마**
- 보존 규칙 (아래)
- 베이스라인, `--since`, 종료 코드 계약, 리포트 형식 `json` · `github-actions` · `sarif` · IDE 클릭용 텍스트
- `skill` — 에이전트용 스킬 설치
- `bridges` — Flutter MethodChannel 생성·호출 사실을 GRAPH-EXCHANGE v1로 출력
- 오탐 코퍼스 + 양방향 검증 스크립트
- 내용 해시와 분석기 신원을 키로 쓰는 해석 결과 캐시

### 나중에 (v0.2+)

- 멀티 패키지(melos 워크스페이스) 지원
- Pigeon 생성 API 형태를 검증한 뒤 추가하는 정적 브리지 추출

### 하지 않는 것

- 삭제 판정 · 자동 삭제 · IDE 플러그인 · 런타임 커버리지 통합
- 린트 규칙 200 개. 그것은 `dart analyze` 와 DCM 의 일이다. 이 도구는 **그래프 위의 질문** 만 답한다
- 포맷터 · 메트릭 대시보드

## 핵심 설계

### 원천: `package:analyzer`

- 배포자 `tools.dart.dev`(Dart 팀), 2026-09-04 기준 14.3.0 이 이틀 전 발행. 활발하다
- `AnalysisContextCollection` 으로 패키지를 열고, 각 파일의 **resolved unit** 에서 요소(`Element`)와 참조를 뽑는다. 이름 있는 요소는 라이브러리 URI + 이름 경로를 정점 ID 로 쓴다. 이름 없는 extension은 선언 source URI + canonical offset을 보조키로 쓰고, `test/` 같은 비패키지 파일은 프로젝트 상대 URI로 정규화한다
- **한계를 처음부터 적는다**: analyzer 는 파일로 남는 산출물이 없어 매 실행 해석한다. 조건부 import(`if (dart.library.io)`) 는 한 구성만 본다. `dart:mirrors` 는 Flutter 에 없으므로 리플렉션 문제는 Swift/Kotlin 보다 훨씬 작다 — 이것이 Dart 의 큰 이점이다

### 보존 규칙

Dart 는 리플렉션이 없어 목록이 짧다. 그래서 더 정확할 수 있다.

- `main()` — **여러 개일 수 있다.** `flutter run -t lib/main_dev.dart`. 기본적으로 `lib/`, `bin/`, `example/` 아래 모든 `main`을 보수적 루트로 본다. 실제 build target을 `dartograph.yaml`의 `entry_points`로 선언하면 그 파일의 `main`만 루트로 좁힌다(구현됨).
- `runApp` 에 넘겨진 위젯 트리 — 도달성으로 자연히 따라온다
- 테스트(`test/`, `integration_test/`), `@visibleForTesting`
- 생성 코드가 참조하는 사용자 선언: `json_serializable` 의 `fromJson`/`toJson`, `freezed`, `build_runner` 산출물이 참조하는 것. 생성 코드는 `synthesized` 로 표시하되 그 참조는 유효한 간선이다
- **플랫폼 채널 이름** — `MethodChannel('com.example/foo')`. 이건 보존 규칙이 아니라 **isthmus 로 내보낼 사실** 이다(아래)
- 라우트 이름 문자열(`Navigator.pushNamed('/settings')`), go_router 경로 — 라우트 테이블이 위젯을 참조하므로 도달성으로 따라온다. 문자열만 있고 테이블이 없는 경우는 `limitations` 에 알린다
- `@pragma('vm:entry-point')` — 네이티브 · isolate 에서 부르는 함수
- Flutter 플러그인 패키지의 `pubspec.yaml` `flutter.plugin.platforms` 가 가리키는 클래스

각 규칙은 `RetentionReason` 값이고 코퍼스에 재현 케이스가 있다.

### isthmus 를 위한 브리지 사실

`dartograph bridges --format json` 이 다음을 낸다. 형식은 `../isthmus/docs/GRAPH-EXCHANGE.md`.

- `MethodChannel` 생성 지점: 채널 이름 리터럴 · 파일 · 줄
- `invokeMethod('name')` 호출 지점: 채널 · 메서드 이름 · 파일 · 줄
- EventChannel·BasicMessageChannel은 v0.1 조인 범위 밖임을 limitation으로 센다
- Pigeon 생성 API의 형태는 아직 검증하지 않았으며 v0.1에서는 별도 의미로 해석하지 않는다

MethodChannel 생성·호출 사실 교환은 v0.1 범위다. isthmus가 첫 번째로 붙일 대상이
Flutter ↔ Swift이기 때문이다.

## 성공 기준

- `doc/PLAN.md` 의 공개 Flutter 프로젝트 3 개에서 돌아가고, 미사용 보고 상위 10 건 손 검증 오탐 0
- 오탐 코퍼스 최소 8 계열, CI 양방향 검증
- `query` 스키마가 cartograph 와 같다
- 자기 분석 findings 0, 커버리지 90%
- `flutter/packages` 크기의 저장소에서 `dead` 가 30 초 안에 — 기준값은 Phase 0 에서

## 비교표 (README 용)

| | `dart analyze` | `lakos` | DCM 무료 | DCM 유료 | dartograph |
|---|---|---|---|---|---|
| 미사용 코드 (전역) | 지역만 | — | ✅ ≤50k LoC, 1인 | ✅ | ✅ 무제한 |
| 미사용 파일 | — | △ orphan¹ | ✅ | ✅ | ✅ |
| 왜 살아남았나 | — | — | — | — | `dead --explain` |
| 순환 의존 + 끊을 후보 | — | 검출만 | — | — | ✅ |
| 에이전트용 질의 | — | — | — | — | `query`, `skill` |
| CI 에 라이선스 키 | 불필요 | 불필요 | 필요 | 필요 | **불필요** |
| 상업적 사용 | 무료 | 무료(MIT) | 제한 | 유료 | **영구 무료** |

¹ `lakos` orphan은 import·피import가 모두 없는 고립 라이브러리라 "어디서도 import되지 않는 파일"보다 좁다. lakos는 라이브러리 단위(`import`/`export`만, `part` 미지원) 시각화·순환·metrics 도구이며 심볼 단위 미사용 코드·근거·에이전트 질의·platform channel은 다루지 않는다.

DCM 열의 사실은 게시 전에 dcm.dev 에서 다시 확인한다. `lakos` 열은 2026-09-06 pub.dev(2.0.7)에서 확인했다.

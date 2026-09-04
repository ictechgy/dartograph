# dartograph 리서치 노트

2026-09-04 기준. **확인됨** 은 1차 출처를 직접 읽은 것, **확인 필요** 는 GLM 또는 기억에서 나온 주장이다.

## 확인됨

### `package:analyzer`

- pub.dev 배포자 `tools.dart.dev`(검증된 배포자, Dart 팀). https://pub.dev/packages/analyzer
- 2026-09-04 기준 최신 **14.3.0, 이틀 전 발행.** 활발하다
- 설명 원문: *"a library that performs static analysis of Dart code."* Dart Analysis Server 가 이 라이브러리 위에 있다고 문서가 말한다(같은 엔진이라고 명시적으로 쓰지는 않음)
- Phase 0에서 8~14의 변경 기록과 14.3.0 실제 컴파일을 대조했다. major마다 element/AST breaking change가 있어 검증한 14.3.x 범위 고정과 어댑터 격리가 필요하다
- 이름 있는 `Element`는 library URI + 이름 경로로 안정 식별할 수 있다. 이름 없는 extension은 source URI + canonical offset 보조키가 필요하고, `test/` 파일 URI는 프로젝트 상대 URI로 정규화해야 한다
- `part`의 `libraryElement.uri`는 호스트 library를 가리킨다. 분석 옵션이 제외한 생성 파일도 같은 context session에 직접 요청하면 resolved unit을 얻을 수 있다

### DCM (구 dart_code_metrics)

- 2023 년부터 유료 제품. https://dcm.dev/pricing/
- **무료 티어 존재**: *"Free: $0 (no card required) For 1 seat"*, 50k LoC 까지, 100 개 린트 규칙, 메트릭, 포맷터, 그리고 *"Unused files, unused localization and incomplete exports detection"* 포함
- 유료: Pro $16/월(1인), Teams $80/월(5~30인), Enterprise 별도
- CI 에서는 `DCM_CI_KEY` 또는 구매 이메일이 필요하다
- **함의**: GLM 은 "DCM 유료 기능에 해당하는 무료 도구가 없어 빈자리가 실재한다" 고 했으나, 무료 티어가 개인 · 소규모를 덮으므로 빈자리는 **팀 · 50k LoC 초과 · 라이선스 키 없는 CI** 로 좁혀진다. PRD 는 이 좁은 정의를 쓴다

### JS/TS 쪽 (RN — 참고)

- `knip`: 미사용 파일 · export · 의존성. 순환은 opt-in. 활발
- `dependency-cruiser`: 레이어 규칙 · 순환 · Mermaid/GraphViz/HTML 출력. cartograph 의 `rules` 와 직접 겹침
- 결론: JS/TS 는 포화. dartograph 는 JS 를 다루지 않는다

## 확인 필요

- **`lakos`** — Dart 의존성 그래프 도구로 기억. 현재 유지보수 상태 미확인. 겹치는 부분이 있으면 README 비교표에 넣는다
- **Pigeon 이 생성한 코드의 형태** — 채널 이름이 생성 코드 안의 상수로 들어가는지, 그러면 `bridges` 가 그것을 "정적 참조" 로 분류할 수 있는지
- **`@pragma('vm:entry-point')` 가 Flutter 에서 실제로 필요한 경우** — isolate 진입점, 플러그인 콜백(`callbackDispatcher`)으로 기억

## Dart 가 Swift · Kotlin 보다 쉬운 이유 (설계에 반영)

- **리플렉션이 없다.** `dart:mirrors` 는 Flutter 에서 쓸 수 없다. Swift 의 `@objc`/셀렉터, Kotlin 의 `Class.forName` 에 해당하는 최대 오탐 원천이 없다
- **Interface Builder / XML 레이아웃이 없다.** UI 가 코드다. 위젯 트리는 도달성으로 자연히 따라온다
- **생성 코드는 만들어지면 소스 파일이다.** `.g.dart` 는 `part of` 또는 독립 library로 귀속된다. 저장소가 산출물을 체크인하지 않을 수 있으므로 신선도와 존재 여부를 함께 확인해야 한다
- 남는 문자열 채널: 플랫폼 채널 이름, 문자열 라우트, `@pragma` 진입점. 목록이 짧다

## cartograph 에서 배운 것 중 여기 그대로 적용되는 것

`../kartograph/docs/RESEARCH.md` 의 같은 절과 동일. 추가로:

- cartograph 의 `SourceFactsCache` 는 **분석기 신원**(도구 버전 + 분석 리비전 + 설정)을 캐시 키에 넣는다. analyzer 버전이 바뀌면 캐시가 무효화되어야 한다 — 캐시를 붙이는 날 이 구조를 그대로

## 출처

- analyzer — https://pub.dev/packages/analyzer
- DCM 가격 — https://dcm.dev/pricing/
- DCM unused code 문서 — https://dcm.dev/docs/cli/code-quality-checks/unused-code/
- knip 비교 — https://knip.dev/explanations/comparison-and-migration

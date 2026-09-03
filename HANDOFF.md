# HANDOFF

새 세션이 이어받기 위한 문서다. 작업 규칙은 [AGENTS.md](AGENTS.md), Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md). 이 파일은 **지금 어디까지 왔고 다음이 무엇인지**만 담는다.

마지막 갱신: 2026-09-04

## 목표

Dart/Flutter 코드베이스의 의존성 그래프를 `package:analyzer`로 만들고, 그 위에서 미사용 코드 · 파일 · 순환 · 레이어 규칙 · 지표를 근거와 함께 답하는 **영구 무료** CLI. [cartograph](../cartograph)의 자매. 자세한 것은 `docs/PRD.md` — 특히 "영구 무료 약속" 절.

## 현재 상태 — 계획만 있고 코드는 없다

- 브랜치 `feature/phase-0-analyzer-validation`이 만들어져 있으나 **커밋은 초안 하나뿐**(`41da5ea docs: 프로젝트 계획 초안`). Phase 0은 착수되지 않았다
- 이 파일과 `AGENTS.md` · `CLAUDE.md` · `.gitignore`(`.serena/`, `asdf-dart.*/`)는 2026-09-04에 다른 세션(cartograph 쪽)이 써 넣었고 **아직 커밋되지 않았다.** 첫 작업 커밋에 `docs:`로 함께 넣으면 된다
- 저장소 루트에 `asdf-dart.*` 디렉터리가 보이면 다른 세션의 SDK 설치 잔재다. `.gitignore`에 넣어 두었다

## 다음 할 일 (순서대로)

1. **Dart SDK 확보.** `dart --version`. 없으면 `asdf`/`fvm`
2. **도그푸딩 대상 클론** — 바탕화면에 Flutter 프로젝트가 **없다.** `flutter/samples`의 앱 하나, `flutter/packages`의 MethodChannel 플러그인 하나(isthmus의 첫 대상), 50k LoC 넘는 오픈소스 앱 하나(`docs/PLAN.md` 0.1)
3. **analyzer 스크립트**(`docs/PLAN.md` 0.2) — `AnalysisContextCollection`으로 앱을 열고 선언 수 · 참조 수 · 실행 시간. 확인할 것: `Element` 식별자의 안정성, `part` 귀속, `.g.dart` 판별, 조건부 import, 캐시 없이 견딜 만한 속도인지, 14.x API가 예제와 얼마나 다른지
4. `docs/DECISION-analyzer.md`에 결과: 정점 ID 규칙, 생성 코드 판별, 캐시 필요 여부(측정값), 고정할 `analyzer` 버전. `docs/PLAN.md` 진행표 갱신
5. Phase 1 골격. `lib/src/index/`가 analyzer를 import하는 유일한 곳이어야 한다

## 미리 알아 둘 것

- **isthmus 세션이 이미 Dart 브리지 추출기를 만들었다**: `../isthmus/experiments/phase-0/dart/lib/dart_bridge_extractor.dart`. `package:analyzer`의 `parseString`(구문 파싱, 해석 없음)으로 `MethodChannel(…)` 생성 지점을 `GRAPH-EXCHANGE.md` 형식의 사실로 바꾸고, 테스트와 픽스처(`experiments/phase-0/fixture/lib/camera_bridge.dart`)가 있다. **이것이 dartograph `bridges` 명령(Phase 4)의 초안이다.** 다만 `parseString`은 해석을 하지 않으므로 한 단계 상수 추적(`const kChannel = '…'`)에는 resolved unit이 필요하다 — Phase 0 스크립트에서 그 차이를 실측하면 좋다
- DCM 무료 티어(1인, 50k LoC)가 미사용 파일·코드 검사를 포함한다. 빈자리는 GLM이 말한 것보다 좁다 — 팀 · 큰 프로젝트 · 라이선스 키 없는 CI. README 비교표를 쓸 때 dcm.dev에서 다시 확인한다
- Dart는 리플렉션이 없고(`dart:mirrors`는 Flutter에 없음) IB/XML도 없어 오탐 원천이 Swift·Kotlin보다 훨씬 짧다. 남는 문자열 채널은 플랫폼 채널 이름 · 문자열 라우트 · `@pragma('vm:entry-point')`. `main`은 여러 개일 수 있다

## 효과가 있었던 / 없었던 방식

아직 없다. `../cartograph/HANDOFF.md`의 두 절이 그대로 적용된다 — 리뷰 주장은 코드로 확인, 테스트는 일부러 부숴서 확인, 오탐의 유일한 원천은 실제 프로젝트 도그푸딩.

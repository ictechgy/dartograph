# HANDOFF

새 세션이 이어받기 위한 문서다. 작업 규칙은 [AGENTS.md](AGENTS.md), Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md). 이 파일은 **지금 어디까지 왔고 다음이 무엇인지**만 담는다.

마지막 갱신: 2026-09-04

## 목표

Dart/Flutter 코드베이스의 의존성 그래프를 `package:analyzer`로 만들고, 그 위에서 미사용 코드 · 파일 · 순환 · 레이어 규칙 · 지표를 근거와 함께 답하는 **영구 무료** CLI. [cartograph](../cartograph)의 자매. 자세한 것은 `docs/PRD.md` — 특히 "영구 무료 약속" 절.

## 현재 상태 — Phase 0 완료

- 작업 브랜치: `feature/phase-0-analyzer-validation`
- `experiments/phase-0/analyzer_probe`에 analyzer 14.3.0 resolved-unit 프로브와 fixture가 있다
- 결정은 `docs/DECISION-analyzer.md`: 버전 고정, 정점 ID, part·생성 코드, 조건부 구성, 캐시 필요성을 수치와 함께 기록했다
- 도그푸딩 대상은 Flutter `navigation_and_routing`, `path_provider` 두 패키지, Invoice Ninja다
- 제품 코드는 아직 없다. 다음은 Phase 1 골격이다

## 다음 할 일 (순서대로)

1. Dart 패키지 골격과 `lib/src/{core,index,analysis,export,cli}/`를 만든다
2. analyzer 14.3.0을 정확히 고정하고 `lib/src/index/` 밖에서 import하지 못하게 한다
3. 모듈 경계 이유를 `lib/AGENTS.md`, 테스트 규칙을 `test/AGENTS.md`에 쓴다
4. 테스트 먼저 `CodeGraph` · `GraphNode` · `GraphEdge` · `EdgeKind.impliesUsage`를 만든다
5. 종료 코드 `0/1/2/64` 계약과 빌드된 바이너리 검증 스크립트를 첫 제품 커밋에 넣는다
6. 캐시 구현 전에도 교체할 수 있도록 core에 fact-cache 경계만 둔다

## 미리 알아 둘 것

- **isthmus 세션이 이미 Dart 브리지 추출기를 만들었다**: `../isthmus/experiments/phase-0/dart/lib/dart_bridge_extractor.dart`. `package:analyzer`의 `parseString`(구문 파싱, 해석 없음)으로 `MethodChannel(…)` 생성 지점을 `GRAPH-EXCHANGE.md` 형식의 사실로 바꾸고, 테스트와 픽스처(`experiments/phase-0/fixture/lib/camera_bridge.dart`)가 있다. **이것이 dartograph `bridges` 명령(Phase 4)의 초안이다.** 다만 `parseString`은 해석을 하지 않으므로 한 단계 상수 추적(`const kChannel = '…'`)에는 resolved unit이 필요하다 — Phase 0 스크립트에서 그 차이를 실측하면 좋다
- DCM 무료 티어(1인, 50k LoC)가 미사용 파일·코드 검사를 포함한다. 빈자리는 GLM이 말한 것보다 좁다 — 팀 · 큰 프로젝트 · 라이선스 키 없는 CI. README 비교표를 쓸 때 dcm.dev에서 다시 확인한다
- Dart는 리플렉션이 없고(`dart:mirrors`는 Flutter에 없음) IB/XML도 없어 오탐 원천이 Swift·Kotlin보다 훨씬 짧다. 남는 문자열 채널은 플랫폼 채널 이름 · 문자열 라우트 · `@pragma('vm:entry-point')`. `main`은 여러 개일 수 있다

## 효과가 있었던 / 없었던 방식

- fixture에서 테스트를 먼저 실패시켜 `part`, 제외된 생성 파일, 조건부 export, 익명 extension 충돌을 고정한 뒤 실제 저장소로 갔다
- 프로젝트가 제외한 파일을 전부 되살리면 대형 앱 진단이 317개로 오염됐다. 정상 analyzed files에 생성 suffix만 합치자 20개로 줄었다
- 대상 저장소가 고정한 Flutter 버전을 맞춰야 `pub get`이 잠금 파일을 바꾸지 않는다. Invoice Ninja는 Flutter 3.44.1에서 전후 해시가 같았다
- LocalSend·Hiddify는 50k 미달, Ente·FlClash는 스택 미달이었다. AppFlowy는 전용 Rust 생성물이 없어 0진단 재현 비용이 과도했다
- analyzer 14.3.0은 Invoice Ninja의 기준 analyzer보다 새로워 프로젝트 자체 분석 0 issues와 달리 진단 20개를 냈다. 참조 정확성 기준값과 성능 관찰을 구분해야 한다

# HANDOFF

새 세션이 이어받기 위한 문서다. 작업 규칙은 [AGENTS.md](AGENTS.md), Claude Code 전용 사항은 [CLAUDE.md](CLAUDE.md). 이 파일은 **지금 어디까지 왔고 다음이 무엇인지**만 담는다.

마지막 갱신: 2026-09-04

## 목표

Dart/Flutter 코드베이스의 의존성 그래프를 `package:analyzer`로 만들고, 그 위에서 미사용 코드 · 파일 · 순환 · 레이어 규칙 · 지표를 근거와 함께 답하는 **영구 무료** CLI. [cartograph](../cartograph)의 자매. 자세한 것은 `docs/PRD.md` — 특히 "영구 무료 약속" 절.

## 현재 상태 — Phase 5 구현 완료

- 작업 브랜치: `feature/phase-0-analyzer-validation`
- `experiments/phase-0/analyzer_probe`에 analyzer 14.3.0 resolved-unit 프로브와 fixture가 있다
- 결정은 `docs/DECISION-analyzer.md`: 버전 고정, 정점 ID, part·생성 코드, 조건부 구성, 캐시 필요성을 수치와 함께 기록했다
- 도그푸딩 대상은 Flutter `navigation_and_routing`, `path_provider` 두 패키지, Invoice Ninja다
- `CodeGraph`와 불변 `GraphSnapshot`, 캐시 경계, analyzer 14.3.0 어댑터가 있다
- `graph --format dot|json|mermaid <package-root>`가 결정적인 출력을 낸다
- `navigation_and_routing`에서 121 nodes · 238 edges를 만들었고 DOT 2회 SHA-256이 일치했다
- `dead --format json`과 `dead --explain`이 보존 경로와 미도달 근거를 낸다
- clean-copy 오탐 코퍼스가 실제 `package:meta`, 정확한 pragma, 다중 plugin class, 생성 코드, 다중 main을 검증한다
- baseline 지문은 줄·열과 limitation 문구가 바뀌어도 안정적이고, 엄격한 버전·도구 검증 뒤 정확히 억제한다
- `--since`는 merge-base 이후 커밋, staged·unstaged, untracked 파일을 NUL 안전하게 합치고 심볼릭 경로를 정규화한다
- text · JSON · GitHub Actions · SARIF 리포터가 finding 근거와 limitation을 보존한다
- 임시 소스 사본과 격리된 pub cache에서 `pub global activate --source path` 계약을 검증하며 원본 `.dart_tool`을 바꾸지 않는다
- `query`가 cartograph `SymbolQueryDocument` 필드로 모호성·양방향 이웃·멤버·도달 경로·baseline 억제·한계를 답한다
- 조건부 directive, 미일치 문자열 route, 오래된 생성 코드가 프로젝트 실제 개수와 함께 limitation에 들어간다
- `skill`이 Dart 고유 삭제 안전 규칙을 출력·설치하며 기존 파일은 `--force` 없이는 덮어쓰지 않는다
- `bridges --format json`이 세 Flutter 채널 종류와 `invokeMethod`를 GRAPH-EXCHANGE v1로 내고 동적·미귀속·파싱 오류 개수를 보존한다
- isthmus Phase 0 실제 fixture 조인은 채널 1, 메서드 1, 미처리 호출 1, 호출 없는 핸들러 2를 재현했다
- 반복형 Tarjan SCC가 20,000 정점 체인과 150개 고정 난수 그래프 오라클을 통과하고 실제 순환 경로·간선·끊을 후보를 낸다
- YAML 레이어 allow/deny 규칙이 같은 레이어를 허용하고 위반 경로·간선·소스 위치를 보존한다
- Martin 지표는 라이브러리별 서로 다른 Ca/Ce, 추상 타입 비율, 0분모·고립 정점 계약으로 계산된다
- `cycles`·`rules`·`metrics`는 일반 모드 0, `--strict` 발견 시 1을 컴파일 바이너리로 검증한다
- analyzer는 표준 Dart 소스 루트만 색인하고 `bin`·`example` main과 동적 디스패치 override를 보존한다
- 자기 분석은 순환 0건이며, dead는 아직 실제 구현에 연결하지 않은 `FactCache` 경계 3건만 남는다
- 전체 제품 라인 커버리지는 Phase 5 끝 기준 91.48%다

## 다음 할 일 (순서대로)

1. `pubspec.yaml`을 0.1.0 공개 메타데이터로 마감하고 CHANGELOG·CONTRIBUTING·SECURITY를 작성한다
2. README 설치·명령·한계·비교표를 실제 CLI와 일치시킨다
3. `dart pub publish --dry-run`과 패키지 산출물 설치 계약을 통과시킨다
4. navigation_and_routing, path_provider 패키지, Invoice Ninja에서 도그푸딩 성공 기준을 재검증한다
5. 자기 분석의 `FactCache` 3건을 구현에 연결하거나 불필요한 경계라면 제거해 findings 0을 만든다

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
- 원본 저장소를 그대로 path activate하면 격리 `PUB_CACHE` 경로가 원본 `.dart_tool/package_config.json`에 기록된다. 설치 검증은 반드시 필요한 소스만 임시 사본으로 옮겨 실행한다
- 구문 기반 bridge 추출은 교차 파일 수신자를 확정하지 않는다. 호출 사실을 `channel: null`, `dynamic: true`와 `unattributed-method-invocations`로 남겨 downstream이 조인하지 않게 한다

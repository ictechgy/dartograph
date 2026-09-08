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
- 실제 `dart:core`의 `@pragma('vm:entry-point')`만 보존 루트가 되고 같은 이름의 가짜 선언은 보존되지 않음을 오탐 코퍼스로 확인했다

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

### `lakos` (Dart 의존성 그래프 도구)

- 2026-09-06 pub.dev 확인: **2.0.7**(확인 시점 최신), verified publisher(olegalexander.com), **MIT**. 143 likes · 7.18k downloads로 활발하다. https://pub.dev/packages/lakos
- 기능: 내부 Dart **라이브러리** 의존성을 Graphviz dot/json으로 시각화, 순환 검출(첫 순환 경로 표시), orphan 식별, metrics(CCD·ACD·NCCD·instability·sloc). CI용 순환 검출 종료 코드.
- **한계(원문)**: *"Only `import` and `export` directives are supported; `library` and `part` are not."* 노드가 라이브러리(파일) 단위이며 **심볼 단위 그래프가 없다.**
- **함의**: dartograph의 `graph`(라이브러리 dot)·`cycles`·`metrics`와 겹친다. 그러나 lakos는 **심볼 단위 미사용 코드 · `dead --explain` 근거 · 에이전트 `query` · platform channel `bridges`를 다루지 않는다.** dartograph의 차별화는 심볼 단위 도달성 + 근거 + 에이전트 표면이다. `doc/PRD.md` 비교표에 반영했다.

### 경쟁·자매 도구 장점 대조 (2026-09-08)

1차 출처(GitHub 원본 README·docs)를 직접 읽었다. cartograph(Swift 자매, v0.8.2),
Periphery(Swift, 현재 상업화·OSS 저장소는 MIT 아카이브), knip(JS/TS), dependency-cruiser(JS/TS),
madge(JS). 아래 "dartograph 현황"은 본 저장소 소스에서 직접 확인한 v0.3.0 기준 상태다.

**dartograph 현황 (2026-09-08 리서치 시점, 소스 확인):**

아래 gap 중 `query --depth/--limit`·`cycles --explain`/`rules --explain`·
`dead --report-test-only`는 이후 구현·머지됐다(PR #24·#25·#26, CHANGELOG Unreleased).
external-retentions는 계약상 dartograph 범위가 아님이 확정됐다(아래 "흡수 후보와 결과" 참조).
Tier 2 후보 4건도 모두 구현·머지됐다(2026-09-08 후반 세션): `affected`(PR #31),
`graph --format html`(PR #32), `graph --level`+`--collapse`(PR #33, module 제외 —
단일 패키지 분석이라 해당 없음), 인라인 ignore 주석(PR #34). 아래 현황 목록은
리서치 시점의 기록으로 남긴다.

- `query`는 이웃 깊이가 `depth: 1`로 고정되고 `truncated`가 항상 false다
  (`lib/src/analysis/symbol_query.dart`). `--depth`·`--limit` 인자가 없다.
- `graph --format`은 `{dot, json, mermaid}`만 받는다(`lib/src/cli/dartograph_cli.dart`).
  html 출력과 `--level`(module/file/type/symbol) 해상도, `--collapse` 폴더 요약이 없다.
- `cycles`는 끊을 후보(`breakCandidate`)를 이미 내지만 `cycles --explain <node>`가 없고,
  `rules --explain <node>`도 없다.
- isthmus 조인을 **되읽지** 못한다: `bridges`로 사실을 내보내기만 하고 external-retentions를
  소비하는 경로가 없다(`lib/`에 `externalBridge` 보존 이유 부재).
- "테스트에서만 도달되는 프로덕션 선언" 개념이 없다(`--report-test-only` 부재).
- 인라인 ignore 주석(`// dartograph:ignore`)이 없고, `dartograph.yaml`은 `entry_points`만 지원한다.
- `init` 명령, `--affected`(변경 영향 반경), markdown·codeclimate·codeowners 리포터가 없다.

**각 도구의 강점 (확인됨):**

- cartograph: `query --depth/--limit`(다중 hop + truncation), `dead --report-test-only`,
  `dead --external-retentions`(isthmus 조인 역방향 소비, reason `externalBridge`, `--explain`이
  증거 인용), `cycles --explain`·`rules --explain`, `graph --level`·`--format html`(자기완결·no-CDN),
  `.cartograph.yml`(include/exclude·thresholds·retention toggle·retained_names/files), `init`.
- Periphery: 인라인 comment command(`// periphery:ignore[:all][:parameters]`, `override kind/location`),
  redundant public 접근성, assign-only property, unused parameter(protocol/override 인지),
  redundant protocol, `--retain-public`·`--report-exclude`·`--retain-files`, `.periphery.yml`.
  상업 제품으로 전환·OSS 아카이브 — 이 프로젝트군이 채우는 자리와 같다.
- knip: `--fix` 자동수정(삭제), `--production`/`--strict`(프로덕션 코드만), issue-type별
  `--include`/`--exclude`·`rules`(error/warn/off), 리포터(codeclimate·codeowners·cycles·disclosure·
  markdown·sarif·json), `--watch`, `--cache`, MCP 서버(`@knip/mcp`)·language server·VSCode/JetBrains,
  100+ 플러그인, 모노레포 1급 지원.
- dependency-cruiser: `--affected <git-ref>`(변경 모듈 + transitive dependents = 영향 반경),
  `--focus`/`--reaches`/`--highlight`, `--collapse`(폴더 단위 요약), `--max-depth`,
  출력 20여 종(err·dot·ddot·archi·flat·mermaid·d2·html·x-dot-webpage·markdown·csv·teamcity·
  azure-devops·json·anon·baseline·metrics·null), `--init`, baseline/`--ignore-known`,
  `depcruise-fmt`(재렌더)·`depcruise-wrap-stream-in-html`.
- madge: `.orphans()`·`.leaves()`·`.depends()`, 순환 노드 색칠 DOT, `--image svg`(GraphViz 직행),
  `--circular --image`(순환만), `--stdin` 파이프.

**흡수 후보와 결과 (2026-09-08 리서치 → 이후 구현):**

구현·머지됨 (CHANGELOG Unreleased, 다음 0.3.x/0.4.0 후보):

- `query --depth/--limit` (PR #24) — cartograph SymbolQueryDocument parity.
- `cycles --explain`·`rules --explain` (PR #25) — cartograph 근거 parity.
- `dead --report-test-only` (PR #26) — cartograph parity, info 심각도.
- `affected <git-ref>` (PR #31) — dependency-cruiser `--affected` 흡수. 변경 라이브러리 +
  import/export 역방향 전이적 종속자, 최단 의존 사슬 path·depth 근거. 라이브러리 수준 관측.
- `graph --format html` (PR #32) — cartograph HTMLGraphRenderer 1차 출처 이식. 자기완결
  (no-CDN) 단일 파일, 캔버스 힘 기반 배치, nodeLimit 400(degree 랭크) + truncatedFrom 정직 보고.
- `graph --level file|type|symbol` + `--collapse <n>` (PR #33) — cartograph GraphLevel·
  dependency-cruiser collapse 흡수. **module 해상도는 제외**: dartograph는 단일 패키지
  분석(의존 패키지는 정점 아님)이라 module 접힘은 단일 정점 — file이 가장 거친 해상도.
  기본 symbol은 byte-for-byte 보존.
- `// dartograph:ignore` (PR #34) — Periphery comment command 흡수. 선언 단위,
  `retentionReason: inlineIgnore` 보존 루트 모델(도달성 전이 — baseline과 대비 문서화).

남은 후보 (미구현 — 범위 결정은 PRD/PLAN에서 한다):

- Tier 3(설정·리포터·에이전트): `dartograph.yaml` 확장(thresholds·include/exclude·retained_*),
  `init`, markdown·codeowners 리포터, issue-type 필터, MCP 서버.
- Tier 4(cosmetic): metrics zone 라벨(zone-of-pain·main-sequence), 순환 노드 색칠, redundant public,
  anon export.

**흡수하지 않을 것 (기존 결정과 충돌):**

- knip `--fix`·자동삭제 → PRD "삭제 판정·자동 삭제 금지".
- IDE 플러그인·language server → PRD "IDE 플러그인 금지".
- melos/모노레포·EventChannel/BasicMessageChannel fact화·`package:args` → HANDOFF 보류 목록.
- assign-only property·read/write 간선 → cartograph도 "아직 known limitation". 고난도(간선 종류 신설).
- `--external-retentions`(isthmus 조인 역방향 소비) → **dartograph 단독 구현 불가, 계약으로 확정.**
  아래 "external-retentions 범위" 참조.

### external-retentions 범위 (2026-09-08 확정)

초기 리서치는 cartograph의 `dead --external-retentions`(isthmus 조인 역방향 소비)를 Tier 1
흡수 후보로 꼽았다. 권위 계약을 직접 읽어 **dartograph 단독으로는 구현 대상이 아님**을 확정했다.

- `isthmus/docs/GRAPH-EXCHANGE.md`(lib/src/index/AGENTS.md가 정본으로 지목)의 "자매 도구가
  해야 할 일" 표가 dartograph의 **읽을 것(consume)** 열을 "(없음 — Dart 쪽이 부르는 쪽)"으로
  명시한다. Flutter↔Swift에서 Dart는 호출측(`MethodChannel`·`invokeMethod`)이고 Swift가
  핸들러측이라, 외부 보존 근거는 핸들러측(cartograph·kartograph)만 소비한다.
- 설치본 isthmus 0.2.0의 `retentions`는 `--for cartograph`만 수용한다
  (`dist/cli/retentions-command.js`가 그 외 값을 usage로 거부). `--for dartograph` producer가
  없고, `CartographRetentionsDocument`(version 0)는 Swift USR/qualifiedName으로 키잉되며
  수신측 Swift 문서를 요구한다.
- dartograph가 소비하려면 (a) isthmus가 Dart 식별자 키의 `--for dartograph` producer를 추가하고
  (b) dartograph `bridges`가 Dart측 핸들러(`setMethodCallHandler`)도 추출해야 한다. (b)는
  GRAPH-EXCHANGE fact-kind 변경이라 HANDOFF 보류("isthmus와 시맨틱 조율 없이 fact kind를
  바꾸지 않는다")와 lib/src/index/AGENTS.md("자매 저장소를 임의로 수정하지 않는다",
  "소비자와 왕복 검증한다")에 막히고, 왕복 검증 상대(isthmus producer)도 없다.

따라서 `lib/`에 `externalBridge` 보존 이유가 없는 것은 결함이 아니라 계약상 범위다. isthmus
선행 작업(producer + GRAPH-EXCHANGE 확장) 없이 dartograph에서 구현하지 않는다.

## 확인 필요

- **Pigeon 이 생성한 코드의 형태** — 채널 이름이 생성 코드 안의 상수로 들어가는지, 그러면 `bridges` 가 그것을 "정적 참조" 로 분류할 수 있는지. 아직 실측하지 않았다. `doc/PRD.md`와 HANDOFF 방침대로 Pigeon 정적 추출은 생성 API 형태를 측정한 뒤에만 추가한다

## Dart 가 Swift · Kotlin 보다 쉬운 이유 (설계에 반영)

- **리플렉션이 없다.** `dart:mirrors` 는 Flutter 에서 쓸 수 없다. Swift 의 `@objc`/셀렉터, Kotlin 의 `Class.forName` 에 해당하는 최대 오탐 원천이 없다
- **Interface Builder / XML 레이아웃이 없다.** UI 가 코드다. 위젯 트리는 도달성으로 자연히 따라온다
- **생성 코드는 만들어지면 소스 파일이다.** `.g.dart` 는 `part of` 또는 독립 library로 귀속된다. 저장소가 산출물을 체크인하지 않을 수 있으므로 신선도와 존재 여부를 함께 확인해야 한다
- 남는 문자열 채널: 플랫폼 채널 이름, 문자열 라우트, `@pragma` 진입점. 목록이 짧다

## cartograph 에서 배운 것 중 여기 그대로 적용되는 것

cartograph의 같은 절과 동일. 추가로:

- cartograph 의 `SourceFactsCache` 는 **분석기 신원**(도구 버전 + 분석 리비전 + 설정)을 캐시 키에 넣는다. analyzer 버전이 바뀌면 캐시가 무효화되어야 한다 — 캐시를 붙이는 날 이 구조를 그대로

## 출처

- analyzer — https://pub.dev/packages/analyzer
- DCM 가격 — https://dcm.dev/pricing/
- DCM unused code 문서 — https://dcm.dev/docs/cli/code-quality-checks/unused-code/
- knip 비교 — https://knip.dev/explanations/comparison-and-migration
- lakos — https://pub.dev/packages/lakos (2026-09-06 확인)
- cartograph(Swift 자매) — https://github.com/ictechgy/cartograph (README, 2026-09-08 확인)
- Periphery — https://github.com/peripheryapp/periphery (아카이브 README, 2026-09-08 확인)
- knip — https://github.com/webpro-nl/knip (packages/docs 원본, 2026-09-08 확인)
- dependency-cruiser — https://github.com/sverweij/dependency-cruiser (doc/cli.md 등, 2026-09-08 확인)
- madge — https://github.com/pahen/madge (README, 2026-09-08 확인)
- isthmus GRAPH-EXCHANGE 계약(정본) — https://github.com/ictechgy/isthmus/blob/main/docs/GRAPH-EXCHANGE.md (2026-09-08 확인)
- isthmus 0.2.0 설치본 — `npm i -g isthmus-cli` 후 `isthmus retentions --help`와 `dist/cli/retentions-command.js`(`--for cartograph`만 수용, 2026-09-08 확인)

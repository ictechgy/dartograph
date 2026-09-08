# Handoff

_Last updated: 2026-09-08 (Tier 2 흡수 완료 세션 — 감사 backlog 후속 + operator 결함 + affected·html·level/collapse·인라인 ignore, PR #29~#35 merge 기준)_

## Goal

- 영구 무료 MIT Dart/Flutter 근거 질의 CLI를 유지한다.
- 이번 세션은 HANDOFF를 읽고 "다음 후보작업 쭉 진행" 지시로 (1) 이전 감사 backlog의
  GLM 후속 2건을 처리하고(PR #29), (2) "extension type의 `.values` 공백 확인" 조사 중에
  재현한 **연산자 호출 usage-edge 누락**(클래스·extension type 공통 오탐)을 수정하고
  (PR #30), (3) RESEARCH Tier 2 흡수 후보 4건을 전부 구현·머지했다: `affected <git-ref>`
  (PR #31, dependency-cruiser), `graph --format html`(PR #32, cartograph 1차 출처 이식),
  `graph --level`+`--collapse`(PR #33, cartograph·dependency-cruiser), `// dartograph:ignore`
  (PR #34, Periphery). 릴리스는 없었다(전부 CHANGELOG `Unreleased`).

## Current Status

- 릴리스 기준: `v0.3.0` → `92826d0` (PR #19 merge). pub.dev(latest 0.3.0)·GitHub Release
  공개 완료.
- main 기준: PR #34(인라인 ignore) merge + 이 HANDOFF를 갱신하는 docs PR(#35).
  이번 세션은 PR #29~#34를 모두 두 SDK CI green + GLM packet-review 후 머지했다.
  열린 제품 PR은 없다.
- 미릴리스 누적(다음 0.3.x/0.4.0 후보, 전부 CHANGELOG `Unreleased`): 이전 세션 3기능
  (`query --depth/--limit`, `cycles·rules --explain`, `dead --report-test-only`) + backlog
  7건(PR #21) + 이번 세션 6건(PR #29~#34).
- 지침 기준: `c4d121d` (PR #7 merge).
- 정본은 루트 AGENTS.md이며 CLAUDE.md는 이를 참조한다. 하위 규칙은 lib, lib/src/index,
  test, fixtures, tool, doc에 있다. 적용 범위는 링크가 아니라 디렉터리 위치로 결정된다.
- 제품 배포 blocker는 없다. HANDOFF 내용이 Git 상태보다 우선하지 않으므로 재개 시 실제 상태를 확인한다.

## Completed

### 이번 세션 (backlog 후속 + operator 결함 + Tier 2 흡수 4건, PR #29~#34)

- **GLM 후속 2건(PR #29)**: (1) `baseline --write`의 `BaselineStore.write`
  FileSystemException이 `on Exception`으로 "unable to index the package"로 오귀인되던 것을
  write 전용 catch로 구분("Baseline write failed: unable to write the baseline file.",
  exit 2 유지). (2) `_escapeMermaid`에 Mermaid 문서화 엔티티 코드 추가: `"`→`#quot;`
  (flow.jison `<string>[^"]+`라 따옴표만 구조를 깬다), `\`→`#92;`, `#`→`#35;`
  (**`#`을 먼저** 바꿔야 이후 도입 코드가 재디코딩되지 않는다 — 단사 인코딩,
  적대적 원문 `#quot;#92;` 회귀로 고정).
- **operator usage-edge 수정(PR #30)**: "extension type의 `.values` 공백 확인"(이전
  backlog) 조사 중에 발견한 같은 계열의 실제 결함. 연산자 구문(`a + b`·`a[i]`·`-a`·
  `a++`·`a += b`)은 SimpleIdentifier가 아닌 토큰이라 `_RelationshipCollector`에서 빠져
  **사용 중인 operator 선언이 dead로 보고**됐다(클래스·extension type 공통, 실측 재현).
  analyzer 14.3.0의 `MethodReferenceExpression.element` 공통 API(Binary·Index·Prefix·
  Postfix·Assignment)로 `call` 간선 기록 + 복합 대입·증감의 인덱스 읽기·쓰기는
  `CompoundAssignmentExpression.readElement/writeElement` 중 **MethodElement만** 보탠다
  (속성 getter·setter는 기존 식별자 경로). `_add`의 양끝 노드 검사로 dart:core 내장
  연산자 자동 필터. 단항 `-`는 lookupName `unary-`로 이항과 ID가 갈린다(실측).
  identity v3→v4. 코퍼스 양방향(보존 `Vector.+`·`Vector.unary-`·`Meters.-` / 보고
  `Vector.*`·`Meters.~/`·`WriteOnly.[]` — 쓰기만 소비된 읽기 연산자).
- **`affected <git-ref> <package-root>`(PR #31)**: dependency-cruiser `--affected` 흡수.
  변경 파일이 귀속되는 라이브러리(씨앗) + import/export **역방향** 전이적 종속
  라이브러리를 JSON으로 답한다. 각 피영향 라이브러리에 최단 의존 사슬 `path`·`depth`
  근거. part 변경은 선언 노드의 `::` 접두로 호스트 라이브러리 귀속. 씨앗 매핑은
  `dead --since`와 동일 canonical 매칭(`_canonicalSource`). 인덱싱→Git 순서로 오귀인
  방지. `unattributedSources`(매치됐으나 라이브러리 노드 부재)를
  `changed-dart-files-without-library` 한계에 합산(조용한 누락 제거). 보고 모드 exit 0.
- **`graph --format html`(PR #32)**: cartograph `HTMLGraphRenderer.swift` 1차 출처 이식.
  외부 CDN·스크립트·폰트 0의 자기완결 단일 HTML — `<script type="application/json">`
  페이로드 + 인라인 캔버스 힘 기반 배치·검색·팬·줌. nodeLimit 400(degree 내림차순·id
  오름차순 동률) 초과 시 `truncatedFrom`+페이지 알림으로 정직 보고. 페이로드 `<`는
  `\u003c`(적법한 JSON 이스케이프 — `</`만 막으면 `<!--<script`가 토크나이저를
  script-data-escaped 상태로 넣어 실제 `</script>`를 삼킨다), `>`는 raw 안전.
  limitations는 헤더 `<details>`+페이로드 양쪽. 적대적 ID(`</script>`·`<!--<script`)
  라운드트립 + 바이트 동일성 회귀.
- **`graph --level file|type|symbol` + `--collapse <n>`(PR #33)**: cartograph
  `GraphLevel`·dependency-cruiser `--collapse` 흡수. `GraphProjection`이 정점을 요청
  해상도의 조상으로 접는다(type: 멤버→**최상위** 컨테이너 전이 닫힘, file: 선언→소속
  라이브러리), 간선은 대표 치환+중복 제거+자기 순환 제거, 대표 노드는 실재 필드 보존.
  기본 symbol은 입력 객체 그대로(`same()`) → **기존 출력 byte-for-byte 보존**(직렬화기
  직행 동일성 테스트). `--collapse`는 project:/package: ID를 앞 n세그먼트로 접고 폴더는
  위치 필드 없는 집계 정점(synthesized는 생성 코드 전용이라 재사용 안 함), `--level file`
  외 결합 usage(64). **module 해상도는 없음**: 단일 패키지 분석이라 module 접힘=단일
  정점(문서화).
- **`// dartograph:ignore`(PR #34)**: Periphery comment command 흡수. 선언 단위 dead
  보고 억제를 `RetentionReason.inlineIgnore` **보존 루트**로 구현 — explain·query·
  compare·test-only에 기존 메커니즘으로 일관 흐름. 해석은 analyzer 토큰 스트림 계약
  (주석은 다음 실 토큰의 precedingComments에 부착 — 프로브 실측): claim 매칭은
  `node.offset` ∪ `firstTokenAfterCommentAndMetadata.offset` ∪ `metadata.first.offset`
  (doc+마커+annotation 조합) + 변수·필드는 감싸는 Field/TopLevelVariable 선언의 claim
  (이들은 fragment null — 노드는 VariableDeclaration이 생성, 실측). 지시문은 `//` 줄
  주석 본문의 **시작** 마커만(doc `///`·블록 주석 제외, `^dartograph:ignore(?![A-Za-z0-9_])`
  — 산문 오발 방지). 같은 줄 꼬리 주석 거부(마커 줄 > 이전 실 토큰 끝 줄), 파일 첫
  토큰의 previous는 EOF 센티널(isEof·offset -1)이라 이전 없음 취급. 사용자 지시가 다른
  보존 이유보다 먼저(단 `_retentionReason`은 항상 평가해 entry_points main 관측 보존,
  plugin 루트도 putIfAbsent 통일). 도달성 루트라 **억제 선언이 참조하는 것도 보고에서
  함께 사라진다**(Periphery 모델 — 단일 finding 억제는 baseline, USAGE에 대비 명시).
  선언만 억제(멤버·파일 비전파). identity v4→v5.
- **docs(PR #35)**: RESEARCH "흡수 후보와 결과"에 Tier 2 4건 이동(module 제외 근거 포함),
  HANDOFF 전면 갱신.

### extension type `.values` 공백 — 확인 완료(이전 backlog 항목 닫음)

- extension type은 `==`·`hashCode`를 **선언할 수 없다**(언어 규칙
  `extension_type_declares_member_of_object` — 실측). enum `.values`류의 암시적 멤버
  소비 표면이 존재하지 않는다.
- 인터페이스 경유 전용 디스패치(extension type·클래스 동일)는 `overrideContract`
  (`@override` 또는 `_overridesInheritedMember`)로 이미 보존된다(실측: `Square.sides`·
  `Triangle.sides` 모두 retentionReason overrideContract).
- 기본 소비 패턴(주 생성자 인스턴스화·named 생성자·static 멤버·implements forwarding·
  타입 표기)은 전부 usage 간선이 생긴다. 미사용 멤버만 보고된다(정확).
- 조사 중 발견한 **같은 계열의 실제 결함은 연산자 호출**(위 PR #30)이었다.
- 결론: extension type에 enum `.values` 공백은 **없다**. 재조사하지 않는다.

### 이전 세션 (0.3.0 릴리스 + 감사 backlog + cartograph parity 3건, PR #13~#28)

- OSS 흡수 리서치(PR #23, `doc/RESEARCH.md`) + cartograph parity 3건: `query --depth/--limit`
  (#24, self-loop 델타 명시), `cycles·rules --explain`(#25, first-match 불변),
  `dead --report-test-only`(#26, info·exit 0). external-retentions는 GRAPH-EXCHANGE 계약상
  **구현 불가 확정**(#27 — 재조사·단방향 구현 금지).
- 0.3.0 릴리스(PR #18·#19): backlog 상위 4건(`_prescanFields`·`isEnumConstant`·빈 채널명·
  `diff.relative=false`) + pub.dev·태그·Release·새 캐시 설치 확인.
- backlog 7건(PR #21), 결함 수정(PR #13~#17), HANDOFF 인계(PR #20·#22·#28).

### 더 이전 세션에서 유지되는 것

- `dartograph.yaml`의 `entry_points`(0.3.0 릴리스): 선언된 build target 파일의 `main`만 보존 루트로 좁힌다.
- analyzer 호환 범위 계약 테스트(PR #10): 런타임 실제 버전이 `doc/DECISION-analyzer.md`의 14.3.x 안인지 강제.
- lakos 리서치 정리(PR #11), `query --batch`·`compare`·소스별 한계 연결·bridge qualifiedName·변형 회귀·벤치마크 도구.
- 0.1.1의 provenance·scope·UTF-8 위치·UTC 밀리초·중첩 캐시·protobuf·CLI 오류 보강.

## Key Files & State

- `lib/src/index/analyzer_graph_index.dart`: analyzer 어댑터. `_RelationshipCollector`에
  operator visitor 4종 + `_addOperatorCall`(MethodReferenceExpression.element) +
  `_addCompoundIndexTargets`(readElement/writeElement 중 MethodElement만). `_DeclarationCollector`에
  `_collectIgnoreClaims`(토큰 스트림 precedingComments + leading 가드 + `_isIgnoreDirective`
  정규식)·`_hasIgnoreClaim`(3-offset + VariableDeclaration 감싼 선언). `_cacheIdentity = v5-inline-ignore`,
  `_cacheSchemaVersion = 2`.
- `lib/src/core/retention_reason.dart`: `inlineIgnore` 추가(사용자 지시 — enum doc 일반화).
- `lib/src/analysis/affected_analyzer.dart`: `AffectedAnalysis.analyze(snapshot, changedSources)`
  → `AffectedResult{changed, affected(AffectedLibrary{id,depth,path}), unattributedSources}`.
  다중 씨앗 FIFO BFS, 동률은 정렬 씨앗·정렬 인접 순.
- `lib/src/analysis/graph_projection.dart`: `GraphLevel{file,type,symbol}` + `GraphProjection.atLevel`
  (symbol은 `same()` identity)·`collapse(graph, depth)`(project:/package: 세그먼트, 폴더=무위치
  집계 정점). `_containerOf`는 전이 닫힘.
- `lib/src/export/graph_exporter.dart`: `html(snapshot, limitations, nodeLimit=400)` +
  `_escapeForScriptTag`(`<`→`\u003c`)·`_htmlKind`(library/type/member)·`_htmlName`.
  `_escapeMermaid`는 6문자(`#`→`#35;` 선행, `&`·`<`·`>`, `\`→`#92;`, `"`→`#quot;`).
- `lib/src/cli/dartograph_cli.dart`: `affected` 명령(`_runAffected` — 인덱싱→Git 순서,
  canonical 매칭, unmapped+unattributed 한계), `_runGraph`의 `--level/--collapse` 추출
  (query `--depth/--limit`과 동일 규약), `_runBaseline` write 전용 catch
  (`_reportBaselineWriteFailure`). help 갱신(html·level/collapse·affected·ignore 문단).
- `lib/src/cli/agent_skill.dart`: affected 항목 + `inlineIgnore`(repository author 지시,
  baseline처럼 존중) 문구.
- `fixtures/false_positive_corpus/lib/operators.dart`(Vector/WriteOnly/Meters — 연산자 양방향),
  `lib/traits.dart`에 `keptByIgnoreComment`·`trailingNotIgnored`(ignore 양방향),
  `lib/main.dart`가 연산자 소비. `tool/verify-false-positive-corpus.sh`는 `-qF` 고정 문자열
  매칭(연산자 ID 메타문자) + 양방향 목록 확대.
- `test/index/fixture/lib/model.g.dart`에 part 파일 ignore 핀(`IgnoredInPart`).
  index 테스트 setUpAll이 `lib/ignored.dart`(마커 8케이스)·`lib/operators.dart` 생성.
- `tool/verify-cli-contract.sh`: affected 4 + graph html/level/collapse 8 케이스 추가.
- 신규 테스트: `test/analysis/affected_analyzer_test.dart`(8)·`test/analysis/graph_projection_test.dart`(8)·
  `test/cli/affected_cli_test.dart`(8)·`test/cli/graph_level_cli_test.dart`(6) + 기존 파일 회귀
  (adoption·graph_exporter·dartograph_cli·analyzer_graph_index).
- `doc/RESEARCH.md`: Tier 2 4건 "구현·머지됨"으로 이동(module 제외 근거 포함), 남은 후보는
  Tier 3/4만. `doc/USAGE.md`: affected·html·level/collapse·inline ignore 절. `README.md`:
  html·affected 예제 줄. `.github/workflows/ci.yml`: Dart 3.11.0/3.13.3 matrix(변경 없음).

## Important Context / Decisions

- Facts:
  - **연산자 간선**: `MethodReferenceExpression.element`가 Binary/Index/Prefix/Postfix/
    Assignment 공통 API(14.3.0). 복합 대입의 인덱스 읽기는 `readElement`(writeElement만
    보면 `Score.[]` 오탐 — 실측). 순수 쓰기(`m[i]=v`)의 IndexExpression.element는 읽기
    간선을 만들지 않는다(실측: `Box.[]` dead 유지 — 가드 불필요). 내장 연산자는
    `_add`의 containsNode 양끝 검사로 필터(ID 공간 `dart:core::` vs `package:…::` 분리).
    단항 `-` lookupName=`unary-`(이항 `-`와 공존 가능, ID 충돌 없음).
  - **affected**: 전파는 import/export 간선만(선언 수준 call/reference는 안 탐 — 라이브러리
    수준 관측, "나열 안 됨=무영향 증명 아님"을 help·USAGE·skill에 명시). `project:` 스킴은
    루트 패키지 전용(projectIdForPath가 루트 밖은 file:// URI) — 의존 패키지 오매칭 불가.
    삭제 파일은 ChangedFiles 계약(`--diff-filter=d`)상 변경 집합에 없음. O(파일수)
    resolveSymbolicLinks는 dead --since와 동일 helper(성능 비차단 수용).
  - **html**: 페이로드가 유일한 동적 데이터, `<` 전량 `\u003c`(cartograph 동일 근거),
    `>`·U+2028/2029는 JSON.parse 입력이라 무해, `]]>`는 브라우저 HTML 계약 밖(XML 체인
    미보증 — 문서화). nodeLimit 400은 cartograph defaultNodeLimit 동일. 터치 입력·색상
    범례는 cartograph 원본에도 없음(parity 범위).
  - **level/collapse**: 접힘은 클러스터 간 인접을 정확히 보존(양끝이 다른 대표인 간선은
    종류 보존 생존), 잃는 것은 클러스터 내부 구조·다중성뿐. member 간선은 접힌 수준에서
    전부 자기 순환(사라짐 — 문서화). `<no-library>` 실재 시 고아 선언은 file 수준에서
    그 정점 하나로 모인다(의도). projection은 graph 렌더링 전용 — dead/cycles/rules/
    metrics/query는 풀 스냅샷.
  - **inline ignore**: 토큰 스트림 계약은 14.3.0 프로브 실측(precedingComments 부착·
    Field/TopLevelVariable fragment null·첫 토큰 previous=EOF 센티널 offset -1·beginToken은
    annotation 포함/doc 제외). 마커와 선언 사이 빈 줄·다른 주석은 허용(코드가 끼면 무효) —
    "바로 위 줄"이 아니다. `int a = 1, b = 2;`의 마커는 둘 다 적용. 비선언 위치(지시문·
    EOF·클래스 `{`) 마커는 조용한 no-op. enum 상수도 선언 단위 억제(컨테이너 enum은 무관).
  - **캐시**: identity는 `dartograph-analysis-$toolVersion-cache-v5-inline-ignore`
    (v4=operator 간선, v5=ignore 루트 — 둘 다 미출시 브랜치에서 흡수, 스키마 v2 불변).
    추출 의미 변경 시 identity 갱신 규약 유지. **개발 중 identity 유지+소스 변경 시 로컬
    캐시가 옛 추출을 재사용한다** — 실측 전에 캐시 삭제(`$HOME/Library/Caches/dartograph`,
    macOS 기준) 또는 새 디렉터리.
  - enum 상수는 `FieldElement`(isEnumConstant), analyzer 14.3.0은 멤버가 `node.body.members`,
    심볼릭 링크는 링크 경로로 해싱, explain witness는 멤버에서 끝남, yaml-3.1.x null 표면,
    소스 한계는 파일 수준 관측, isthmus가 언어 간 조인 소유 — 이전 세션 사실 유지.
  - **external-retentions는 dartograph 범위 아님**(GRAPH-EXCHANGE 계약 확정, PR #27). 재조사·단방향 구현 금지.
- Assumptions:
  - Mermaid 엔티티 코드(`#quot;`·10진 코드·`#35;`)는 flowchart.md 문서 + flow.jison
    `<string>[^"]+` 문법 + diagram.spec.ts 플레이스홀더 변환으로 확인했다(develop 브랜치,
    2026-09-08). 렌더러 버전별 차이는 미실측.
  - cartograph html·level 이식은 1차 출처(main 브랜치 소스)를 직접 읽었으나 Swift→Dart
    번역의 행동 동등성은 브라우저 실렌더링이 아니라 페이로드·구조 테스트로 고정했다.
  - HANDOFF의 검증 수치는 아래 명시한 작업의 기록이며 이후 변경까지 보증하지 않는다.

## Verification

- 이번 세션 검증(PR #29~#34): SDK homebrew `dart 3.13.3`, 격리 PUB_CACHE 온라인.
  각 PR마다 `dart format`·`dart analyze` clean, 전체 테스트 통과(#29 186 → #30 187 →
  #31 202(rebase 후) → #32 209 → #33 223 → #34 **224**), 라인 커버리지 94%대
  (최종 **94.44%**, ≥90 게이트), 오탐 코퍼스 양방향·cli-contract(55케이스)·
  clean git `dart pub publish --dry-run` 경고 0. **6개 PR 모두 두 SDK(3.11.0/3.13.3)
  CI green 후 머지.** check-analyzer-boundary.sh는 로컬 rg 부재로 CI 위임(샌드박스에
  ripgrep 없음 — 이번 세션 환경 사실).
- **로컬 커버리지 실행법(유지)**: `dart --enable-vm-service=$AGENT_GUARD_LOOPBACK_PORT
  --no-dds --disable-service-auth-codes test --coverage=<dir>` 후
  `dart run coverage:format_coverage -i <dir> --report-on=lib --lcov -o <dir>/lcov.info`
  (주의: `-i` 플래그다, `--coverage` 아님). awk LF/LH로 비율 계산.
- **GLM packet-review 7회**(본 6 + delta, `--provider glm --effort high --files` 단독 —
  `--diff` 단독은 래퍼 버그). 시간당 6회 제한이라 다중 PR 세션은 페이싱 필요. 결과:
  #29 차단 없음(단사성 테스트 반영, catch 확대·help 문구 기각), #30 차단 없음(N1 복합
  인덱스 readElement 재현 후 수정·N6 순수 쓰기 코퍼스·N8 unary-/이항 공존 핀),
  affected 차단 없음(a 인접 정렬·b project: 전용 확인·c unattributedSources 반영),
  html 차단 없음(적대적 ID·바이트 동일성 테스트 반영, 터치·범례는 parity 기각),
  **level B1 차단**(type 접힘 전이 닫힘 부재 → 수정+회귀), **ignore B1~B3 차단**
  (doc+marker+annotation 조합·변수/필드 귀속·산문 오발 → 전부 재현·수정·핀 추가,
  리뷰어 "수정 후 재검토 없이 merge" 판단).
- 각 기능은 **기존 출력 보존을 회귀로 잠갔다**: #29 기존 golden 불변, #30 미사용 연산자
  보고 유지(양방향), #32 html 신규(기존 형식 불변), #33 symbol 기본값=직렬화기 직행
  byte 동일, #34 마커 없는 코퍼스·fixture 출력 불변.
- 아래는 이전 세션 기록이다.
- 0.3.0 릴리스(PR #18·#19): 전체 139개 테스트, dry-run 경고 0(70 KB), pub.dev 게시·태그·
  GitHub Release·새 캐시 설치 확인. 게시는 자격 증명을
  `~/Library/Application Support/dart/pub-credentials.json`로 복사 후 토큰 인증.
- `dart run tool/benchmark_query.dart`: 합성 2,000노드/100질의 약 227ms → 8ms(실제 SLA 아님).
- `dart run tool/verify_bridge_query.dart <isthmus-main.js>`: 합성 Swift fact 왕복(실제 compiler 검증 대체 아님).

## Blockers & Open Questions

- 필수 제품 작업 없음. 열린 제품 PR 없음.
- **external-retentions는 isthmus 선행 작업 없이는 구현 불가**(GRAPH-EXCHANGE 계약, PR #27).
  재조사·단방향 구현 금지.
- 아래 목록은 다르다. **남은 흡수 후보**는 근거가 확인된 미구현 항목, **닫은 항목**은
  다시 도출하지 말 것, **보류 항목**은 요구·측정·외부 조율이 생기면 재검토.

### 남은 흡수 후보 (RESEARCH.md "남은 후보")

**Tier 2는 이번 세션에 전부 구현·머지됐다(#31~#34).** 새 요청 없으면 범위 결정은
PRD/PLAN에서 한다.

- Tier 3(설정·리포터·에이전트): `dartograph.yaml` 확장(thresholds·include/exclude·retained_names/files),
  `init`(설정 템플릿), markdown·codeowners 리포터, issue-type 필터, MCP 서버(knip `@knip/mcp`).
- Tier 4(cosmetic): metrics zone 라벨(zone-of-pain·main-sequence), 순환 노드 색칠(madge),
  redundant public(Periphery), anon export(dependency-cruiser).

### 검토 후 닫은 항목 (간과가 아님)

- **extension type의 `.values` 공백**(이전 backlog): 언어가 extension type의 `==`·`hashCode`
  선언을 금지하고 인터페이스 디스패치는 overrideContract로 보존되며 기본 소비 패턴은 전부
  간선이 생긴다 — 공백 없음. 조사 중 발견된 실제 결함(연산자 usage-edge)은 PR #30으로 수정.
  재조사하지 않는다.
- **GLM 후속 2건**(이전 backlog): baseline 쓰기 오귀인·Mermaid 따옴표/역슬래시 — PR #29로 처리.
- bridges limitation "보강", 대형 모듈 분리, HANDOFF 커밋 표류·`.dart_tool` 기록,
  `.pubignore` 유출 주장 — 이전 세션 근거 유지(재도출 금지).
- html의 터치 입력·색상 범례·isAbstract 표시, rAF 상시 draw, 드래그 후 click — cartograph
  원본과 동일(parity 범위 초과 확장, 비차단 기각 기록).
- collapse의 잘린 간선 수 보고 — 유지 정점 집합의 결정적 결과이고 알림이 dot으로 안내(중복 계수).

### 이전 감사 backlog — 선택 과제(남음, 근거 없이는 착수 금지)

- `code_graph.dart` `nodes` 게터 hoist(**수치 근거 없음**), `architecture_metrics_test.dart:47`
  정렬 규칙 미구별, 테스트 9곳 `FactCache` 미주입(개발자 머신 한정), `lib/dartograph.dart`의
  `ReachabilityResult` 미export(지원 API 여부 먼저 결정), `metrics --strict` tolerance 0.3
  미문서화, analyzer 버전 캐시 키 부재(global activate 한정), `query --baseline`의 dead
  **file** 항목 미억제(명령 간 finding 집합 어긋남), `doc/PRD.md` 경쟁 비교표 README 부재.

### 검토 후 보류한 항목 (간과가 아님)

- `package:args` 전환, isolate 병렬화 cold-run 30초 SLA, melos 멀티패키지(PRD v0.2+),
  EventChannel·BasicMessageChannel fact화(isthmus 조율 없이 fact kind 변경 금지),
  무료·JSON·MCP 해자 가설 — 이전 세션 근거 유지.

## What Worked / Avoid

- **1차 출처 이식은 원본 소스까지 읽는다.** cartograph HTMLGraphRenderer·GraphBuilder·
  GraphLevel, Mermaid flowchart.md+flow.jison+diagram.spec을 직접 읽어 escape 정책·
  nodeLimit·level 의미·엔티티 코드 메커니즘을 추측 없이 이식했다. README만 보고 판단하면
  external-retentions(PR #27) 같은 범위 오류나 escaping 오구를 만든다.
- **analyzer API는 문서가 아니라 프로브 스크립트로 실측한다.** 이번 세션에 문서/기억과
  실측이 3번 갈렸다: FieldDeclaration·TopLevelVariableDeclaration의 `declaredFragment`는
  null(노드는 VariableDeclaration이 생성, 마커는 감싸는 선언 토큰에 부착), doc comment가
  있으면 `beginToken.precedingComments`가 비고 체인이 키워드 토큰에 이동, 파일 첫 토큰의
  `previous`는 offset -1 EOF 센티널. 임시 프로브는 저장소 루트에 만들어 돌리고 **삭제**한다.
- **backlog "확인" 항목은 대조군 실험으로 판정한다.** extension type 조사는 클래스 대조군
  덕분에 overrideContract 정상 동작과 연산자 공통 결함을 분리했다. "미재현" 기록만 믿지 말고
  소비 패턴 행렬(인스턴스화·static·인터페이스·연산자·복합 대입)을 직접 돌린다.
- **GLM 차단은 재현부터**: level B1·ignore B1~B3 모두 합성 입력으로 재현 후 수정·핀 추가.
  비차단도 패킷 밖 근거로 검증해 반영(unattributedSources)/기각(catch 확대·synthesized
  재사용·touch·범례)하고 이유를 PR에 남겼다.
- **개발 중 캐시 오염 주의**: identity를 올린 뒤 같은 identity 내에서 추출 로직을 다시
  바꾸면 로컬 캐시가 옛 추출을 재사용해 실측이 왜곡된다(idx-compound 재현 착각). 캐시 삭제
  (`$HOME/Library/Caches/dartograph`) 또는 새 scratch 디렉터리로 확인한다.
- **미커밋 작업은 올바른 베이스 브랜치로**: affected 작업을 operator 브랜치 위에서 시작했다가
  `git stash -u` → main → 새 브랜치 → `stash pop`으로 옮겼다. 커밋 전 `git branch --show-current`.
- **dry-run은 clean git에서만 경고 0** — 미커밋 변경 자체가 경고다. 커밋 후 실행.
- **packet-review는 시간당 6회** — 다중 PR 세션은 본/delta 리뷰를 페이싱하고, delta가 리뷰어
  자신의 권고를 기계적으로 구현한 경우 재전송을 생략할 수 있다(PR #33 delta).
- **한국어 산문에 외국어 혼입을 경계**: 이번 세션에 커밋 메시지·주석·문서에 한자·일본어가
  여러 번 섞여 amend·재편집했다. 제출 전 diff를 다시 읽는다.
- 샌드박스: rg 없음(grep 도구 실패 → bash grep, check-analyzer-boundary는 CI 위임),
  Write 도구는 워크스페이스 밖 거부(PR 본문은 bash heredoc으로 `$TMPDIR/opencode/`에),
  커버리지는 전용 포트, `git push -u`의 .git/config 쓰기 경고는 무해(push 자체는 성공 —
  ls-remote로 확인).
- **반쪽 수정을 남기지 않는다 / 게이트 명령은 각각의 exit code를 따로 확인한다 / `Directory.current`는
  프로세스 전역 / 테스트가 상대 경로로 파일을 쓰면 저장소를 오염시킨다(PR #17) / 수정 전 실패 재현은
  올바른 기준 커밋으로 / main에 직접 커밋하지 않는다 / 기본값 출력 보존은 회귀로 잠근다** — 계속 유효.
- `dart pub get` 전에 `dart analyze`를 돌리면 가짜 error가 대량으로 뜬다. Markdown에 dart format을
  실행하지 않는다. pub.dev 전파 지연 시 동일 버전 재게시 금지. analyzer API는 설치된 소스(격리 캐시)에서
  확인한다. dep-free 픽스처(relative import만)는 pub get 없이 analyzer가 해석한다.

## Next Steps

1. 실제 branch/status/log를 확인하고 루트 및 작업 경로의 AGENTS.md를 읽는다.
2. 이번 세션은 PR #29~#34(+docs #35)를 머지했고 **전부 미릴리스**(CHANGELOG `Unreleased`)다.
   완료된 구현·기록을 반복하지 않는다.
3. 남은 흡수 후보는 `doc/RESEARCH.md`의 **Tier 3/4만**이다(Tier 2 완료). **external-retentions는
   isthmus 선행 작업 없이 구현 불가(계약 확정, 재조사 금지).** 새 사용자 요청이 없다면 범위
   결정은 PRD/PLAN에서 한다.
4. 선택 과제 backlog는 위 근거(수치 없음)를 먼저 읽고 다시 도출하지 않는다. 닫은·보류 항목 동일.
5. 릴리스는 지시 시에만: pubspec·toolVersion·CHANGELOG·설치 예제·SECURITY 버전을 맞추고 clean git
   dry-run 후 게시(CONTRIBUTING 정본). 미릴리스 누적 = 이전 3기능 + backlog 7건 + 이번 세션
   6건이 다음 0.3.x/0.4.0 후보다. **릴리스 시 캐시 identity v5는 0.3.0(v3) 사용자 캐시를
   자동으로 무효화한다**(toolVersion도 키에 포함 — 이중 안전).

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/dartograph`, read `HANDOFF.md` and applicable
`AGENTS.md` files, then continue from: `Verify current Git state. Product 0.3.0 is released
(pub.dev latest 0.3.0, tag v0.3.0). This session cleared the audit-backlog GLM follow-ups
(baseline write attribution + Mermaid quote/backslash/hash entity escaping, PR #29), fixed a real
false-positive family found while closing the extension-type .values backlog item — operator
invocations (a+b, a[i], -a, a++, m[i]+=v) produced no usage edges for classes or extension types
(PR #30, MethodReferenceExpression.element + compound readElement/writeElement, cache identity v4) —
and implemented ALL four RESEARCH Tier 2 absorptions: affected <git-ref> (PR #31, dependency-cruiser,
library-level reverse import/export BFS with shortest-path evidence), graph --format html (PR #32,
cartograph HTMLGraphRenderer port, self-contained no-CDN, nodeLimit 400, \u003c script-tag escaping),
graph --level file|type|symbol + --collapse <n> (PR #33, GraphProjection with transitive container
folding; NO module level — single-package analysis; symbol default is byte-identical), and
// dartograph:ignore (PR #34, Periphery-style, retentionReason inlineIgnore, token-stream
precedingComments parsing with leading-comment guard, directive must head a line comment, reachability
closure documented vs baseline, cache identity v5). The extension-type .values gap is CLOSED (language
forbids ==/hashCode on extension types; interface dispatch already retained via overrideContract; do
NOT re-investigate). All six PRs merged with two-SDK CI green and GLM packet-review (blocking issues
in #33/#34 were reproduced, fixed, and pinned; reviewer approved without re-review). Everything is
UNRELEASED (CHANGELOG Unreleased) with prior backlog. Remaining absorption candidates are Tier 3/4
only; external-retentions stays contract-blocked (PR #27). Local coverage runs via the dedicated port
($AGENT_GUARD_LOOPBACK_PORT, format_coverage uses -i); packet-review must use --files (not --diff) and
is rate-limited to 6/hour; ripgrep is absent locally (check-analyzer-boundary delegated to CI); clear
$HOME/Library/Caches/dartograph when re-measuring extraction changes within an unreleased identity.
Follow the next explicit user task.`

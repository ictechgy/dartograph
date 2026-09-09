# Handoff

_Last updated: 2026-09-09 (후속: issue #38 양측 종결·close(PR #57 docs) + **죽은 공개 API 처분(PR #58 — 정책 A 최소화·hygiene)** → 미릴리스 누적 PR #58 생김; isthmus GRAPH-EXCHANGE 문구 갱신(isthmus PR #36 realpath + #37 조인 루트) 확인 후 issue #38 마감 코멘트(issuecomment-5602011319)·close(reason: completed); 선행 세션: 전체 감사 + 수정 6건 + 영어 문서 전환 + 0.4.1 + 성능 3건 + bridges 공유 루트 + **0.5.0 릴리스** + issue #38 dartograph 측(PR #52), PR #39~#58 merge)_

## Goal

- 영구 무료 MIT Dart/Flutter 근거 질의 CLI를 유지한다.
- 이번 세션은 (1) 사용자 지시로 README·CHANGELOG를 **영어 정본**(pub.dev 노출)으로
  전환하고 한국어본을 `README.ko.md`·`CHANGELOG.ko.md`로 분리했으며(PR #39),
  (2) "코드 전체적 리뷰(성능·보안·구조)" 지시로 제품 코드 6,684줄 전량 감사를
  수행하고(직접 검토 + explore 하위 에이전트 3축 + GLM 교차검증 3패킷, 중요 지적은
  전부 실측·코드 대조 재검증), (3) 감사 결함 수정 6건을 머지하고(PR #40~#45),
  (4) 사용자 승인("감사 수정과 묶어서")에 따라 **0.4.1을 릴리스**했고(PR #46 —
  pub.dev·태그 v0.4.1·GitHub Release·새 캐시 설치본 검증), (5) 이어서 사용자
  지시("1번 ㄱㄱ")로 감사 성능 backlog를 **측정 선행 규칙**대로 처리했고
  (PR #48~#50 — A/B 하네스 신설, 인덱싱 -28%·query 배치 -84%·rules -72%,
  7종 산출물 해시 전후 동일), (6) 이어서 "이슈 38 처리해줘" 지시로 isthmus
  모노레포 조인 요청의 dartograph 측 구현을 완료했고(PR #52 — bridges
  `--project` + pub workspace 자동 감지, 설치본 isthmus 왕복 실측), (7) "릴리즈해줘"
  지시로 성능 3건 + bridges를 **0.5.0으로 릴리스**했다(PR #54 — pub.dev·태그
  v0.5.0·GitHub Release·설치본 검증, issue #38 코멘트도 권한 부여 후 게시).

## Current Status

- 릴리스 기준: **`v0.4.1` → `53a4e0f`** (PR #46 merge). pub.dev(latest 0.4.1,
  Readme·Changelog 탭 **영어**)·GitHub Release 공개 완료. 새 격리 캐시 설치본으로
  `--version`·`report` 필드·Mermaid `#10;` 단일행·CLI 계약 55케이스 확인.
- main 기준: 0.5.0 릴리스(PR #54) + HANDOFF 기록(#55·#56) + issue #38 close(#57) +
  죽은 공개 API 처분(#58). 이번 세션은 PR #39~#55를 모두 두 SDK CI green + GLM
  packet-review 후 머지했다(#57·#58도 동일 — #58은 GLM 리뷰 차단 없음).
  열린 제품 PR 없음. **이 세션의 작업은 여기서 마감 — 나머지는 전부 다음 세션
  이월분이다(Next Steps 4의 목록).**
- **미릴리스 누적: PR #58(죽은 공개 API 처분 리팩터)** — lib/ 변경(querySymbol·
  usageEdgesFrom 제거, SymbolQuerySession.analysis→deadDeclarations getter, DeadFinding
  export)이 미릴리스. **CLI 출력·종료코드 무변경**(getter는 위임만)이고 라이브러리
  API 표면 변경(문서화·외부 소비자 없음). CHANGELOG는 관례상 `Unreleased` 절이
  없으므로 **다음 릴리스 때 semver+CHANGELOG로 기록한다**(Current Status·Next Steps 5).
  PR #57(issue #38 close)은 HANDOFF-only(.pubignore로 패키지 제외)라 누적이 아니다.
- 테스트 253개, 라인 커버리지 **95.98%**(감사 전 94.4%; PR #58이 미커버 querySymbol
  제거 + getter 스모크 추가로 소폭 상승).
- 지침 기준: `c4d121d` (PR #7 merge). 정본은 루트 AGENTS.md, 하위 규칙은 lib·lib/src/index·
  test·fixtures·tool·doc. **pub.dev 노출 문서(README·CHANGELOG)는 영어가 정본이고
  `.ko.md` 쌍과 내용을 동기화한다(CONTRIBUTING 정본 규칙).**
- 제품 배포 blocker 없음. HANDOFF가 Git 상태보다 우선하지 않으므로 재개 시 실제 상태 확인.

## Completed

### 이번 세션 (영어 문서 + 전체 감사 + 수정 6건 + 0.4.1, PR #39~#46)

- **영어 정본 전환(PR #39)**: README·CHANGELOG 전량 영어화(0.1.0~0.4.0 전 버전),
  한국어본 분리·상호 링크, CONTRIBUTING에 쌍둥이 동기화 규칙·`(Korean)` 표기 규약·
  릴리스 체크리스트(두 언어 CHANGELOG). `.ko` 쌍은 .pubignore로 패키지 제외(pub의
  변형 파일명 경고 회피, GitHub 링크 유효). GLM 번역 충실성 전수 대조 "누락·왜곡·과장 없음".
- **전체 감사(수정 아님 — 기록)**: 구조·성능·보안·정확성·테스트 5축. 방법: 직접 검토 +
  explore 3병렬 + GLM 3패킷, 모든 중요 지적 실측/코드 대조 검증. 산출: 보안 5건(S1~S5),
  출력 계약 8건(E1~E8), 성능 10건(P1~P10), 구조·테스트 공백(T1~T6+죽은 API 3).
  아래 "남은 감사 backlog"가 미처리분.
- **PR #40 제어문자 정책 통일**(E1·E2·E8): 개행 파일명의 Mermaid 문장 절단(실측 주입)·
  text 진단줄 위조(실측)·GH ESC/bidi 통과·SARIF `Uri(path:)` 손상(`back\slash`→
  `back/slash`, `%41`→`A` 실측) 수정. 정책 정본 표가 graph_exporter 클래스 문서.
  Mermaid CR·LF→`#13;`·`#10;`(한 물리행, `#35;` 선행으로 리터럴 라운드트립),
  text C0·DEL 가시 이스케이프, GH 퍼센트 인코딩 확장(C1·U+2028/9·bidi), SARIF
  `Uri(pathSegments:)`, DOT CR 대칭. 정상 입력 byte 불변(기존 골든 무수정 통과).
- **PR #41 오류 경계·귀인**(S2): `runDartograph` = `_dispatch` + `on Object` 최후 방어
  (Error 계열 → 스택트레이스·exit 255 대신 계약된 2). bridges 제어문자 거부는
  "Bridges extraction failed"로 구분, git 비-UTF8 출력은 ChangedFilesException 수습 +
  decode를 순수 함수 `decodeChangedFilesOutput`로 추출(플랫폼 무관 회귀).
- **PR #42 캐시 키 커버리지**(S1 높음): 키가 표준 5디렉터리만 해싱해 `tool/` 등
  루트 안 비표준 .dart 변경 시 stale hit(limitation 소멸 실측 재현). 루트 전체 열거로
  확장(중첩 패키지 탐지 통합), `.fvm`류 숨김 디렉터리 가지치기(`skipHiddenDirectories`
  — SDK 전체 해싱 폭주 방지), 루트 밖 상대 import는 문서화된 경계. identity v5 유지
  (키 입력 확장이라 옛 키 자연 미스).
- **PR #43 출력 충실성**(E3~E7): dead json `report` 필드(dead/test-only 기계 분류),
  GH baseline 억제 notice(>0만), graph json 조건부 `isEnumConstant: true`(캐시 문서
  정합), SARIF 파일 finding region 발명 제거, `generated-code-staleness` mtime 의존을
  선언된 결정성 예외로 문서화(USAGE·lib/AGENTS).
- **PR #44 symlink 스코프·설정 가시성**(S3~S5): `_changedContains` 양방향 매칭
  (미해석 링크 경로 OR 해석 실 경로 — 링크 retarget 누락 실측 수정), affected는
  canonical null=비매치(삭제 파일 오보 방지, dead와 의도적 비대칭·주석 고정).
  `entry_points` 선언 시 `entry-points: main retention roots narrowed to N ...`
  limitation(설정의 조용한 보존 좁힘 차단). SECURITY.md에 심볼릭 링크 유입 채널 문서화.
- **PR #45 테스트 공백**(T1~T3): cli 4그룹(usage 거부·rules 성공 0·실패 catch·기본
  인덱서 배선 스모크), layer_rules 설정 오류 5분기 + `?` glob 실동작, GraphNode 모순
  플래그 가드 + ==/hashCode 일관. 커버리지 94.4→95.9%.
- **0.4.1 릴리스(PR #46)**: 버전 정합 6곳 + 두 언어 CHANGELOG 마감. GLM 릴리스 리뷰
  비차단 3건 반영(entry-points limitation 문서화, --level 기본값 문구 한정, 캐시 자동
  무효화 노트). clean git dry-run 0 → publish → 태그 v0.4.1=`53a4e0f`(게시 커밋) +
  GitHub Release(`--target` 사용) → 전파 ~7분 후 새 캐시 설치본 검증(계약 55케이스).
- **0.5.0 릴리스(PR #54)**: bridges 공유 루트(#52, 새 사용자 옵션 → semver minor) +
  성능 3건(#48~#50) 마감. 버전 정합 6곳 + SECURITY `0.5.x` + 두 언어 CHANGELOG.
  GLM 릴리스 리뷰 비차단 2건 반영(제어문자 **메시지** 정정이 동작 불변임을 명시 —
  경로 검증은 0.3.0부터 존재, USAGE에 경로 거부·진단 귀속 보강; KO 헤드라인 어순).
  clean git dry-run 0 → publish → 태그 v0.5.0=`16b18fd`(게시 커밋, `--target`) +
  GitHub Release(0.4.1 대비 바이트 변경 지점 요약 포함) → 전파 ~4분 후 새 캐시
  설치본 검증(workspace 감지 project=모노레포 루트·재기준 경로, override 0,
  containment 위반 64, 계약 59케이스).

- **성능 backlog 측정 수정(PR #48~#50, 0.5.0에 포함)**: 측정 선행 규칙에
  따라 A/B 하네스 `tool/benchmark_index.dart`를 신설했다(합성 dep-free 600파일 패키지
  결정적 생성 — 파일당 클래스+메서드 3+필드+최상위 함수, 배럴이 1/3 export, test가
  main 궤적 밖 파일 import로 test-only 342건; cold 인덱싱 3회 + analyze·test-only·
  query·rules 5회 반복 최소값; graph·dead·query·retention·test-only·limitations·rules
  **7종 산출물 sha256**으로 출력 동등성 고정 + run별 해시 대조로 비결정성 차단).
  - **#48 인덱싱 -28%**(min 1456→1053ms): P1 `_RelationshipCollector`의 element→ID
    메모(`_idOf` — 식별자 방문마다 projectIdForPath 재계산 제거), P2 `CodeGraph.nodes/
    edges` 읽기 뷰 캐시+변경 시 무효화 & `_addPublicApiRoots`의 노드 ID 목록 export
    루프 밖 hoist, P9 간선 비교자 `compareGraphEdges` 일원화(CodeGraph·GraphSnapshot·
    usageEdgesFrom 공유 — 감사 T5의 정렬 로직 중복도 함께 해소), P10 pubspec 인덱싱당
    1회 읽기·선언당 source 1회 계산.
  - **#49 query 배치 -84%**(10.7→1.7ms): P3/P6 `ReachabilityResult.isReachable`(Set)·
    `reachableMemberOf`(dot-접두 witness 색인 1회 구축 — 정렬 순 putIfAbsent가 기존
    firstOrNull과 동치, 주석 근거) — explain·symbol_query·compare._loss의 질의별 O(R)
    선형 주사 제거. P5 analyze reachableIds 이중 정렬 제거. compareGraphs limitations
    dedup+sort 1회 hoist. analyze 5.7→4.7ms.
  - **#50 rules -72%**(10.8→3.0ms): P4 `LayerRuleEvaluator` 패턴별 RegExp 캐시
    (first-match가 미매치 노드마다 전체 패턴 재컴파일하던 것 제거, const 생성자 해제),
    P8 `dead --since` 고유 source당 링크 해석 1회 메모(`_changedContains` 동기화 +
    메모 누락 assert).
  - 세 PR 전부 7종 해시 전후 동일 + 244 테스트 무수정 통과 = 출력 byte 보존의 증거.

- **bridges 공유 루트(PR #52, issue #38 = isthmus의 모노레포 조인 합의 요청)**:
  GRAPH-EXCHANGE(isthmus 정본)가 "공유 루트 선언 방식은 생산자 옵션(dartograph#38
  등)으로 정해지는 대로 계약에 추가"로 위임했고, 조인은 문서 간 `project` 문자열
  정확 일치 fail-closed다. 제안 (a)+(b) 병행 구현:
  - **(a) `bridges --project <shared-root>`**: 스캔은 위치 인자(package-root) 유지,
    `project` 필드·`location.path`를 공유 루트 기준(realpath)으로 재기준. 검증:
    기존 디렉터리 + package root를 포함하거나 동일(위반·미존재·중복·값 빠짐·옵션
    모양·**빈 값**=cwd 조용한 해석 → usage 64, 경로 미반향 메시지). `indexBridges`도
    containment를 ArgumentError로 강제(이중 방어).
  - **(b) pub workspace 자동 감지**: 스캔 루트 pubspec의 `resolution: workspace` →
    `workspace:` 키를 가진 가장 가까운 조상 pubspec 디렉터리(Melos 정의 동일)을
    realpath로 채택. 실패(조상 부재·pubspec 파싱 불가)는 스캔 루트 폴백 +
    `pub-workspace-root-not-found`·`pub-workspace-pubspec-unparsed` limitation
    (조인 기준 어긋남 가시화). 우선순위: --project > 감지 > 스캔 루트.
  - 기본 출력 byte 동일(선언·옵션 없으면 project=스캔 루트 realpath — 기존 골든
    무수정). **isthmus 설치본 왕복 실측**: workspace 감지 문서와 --project 문서의
    project 문자열 일치, 합성 swift 문서 포함 3문서 `isthmus check` 성공(evidence에
    재기준 경로 보존), 불일치 문서는 거부 — 문제 실재와 해소를 양방향 실증.
  - **isthmus 측 전달 의미론(계약 문구 갱신용 — issue 코멘트 게시 완료:
    issuecomment-5599285065)**: project는 생산자 선언값이며 (a) 명시
    --project, (b) resolution: workspace 시 workspace: 키를 가진 최근접 조상
    pubspec 디렉터리, (c) 없으면 스캔 루트의 POSIX realpath. 모든 location.path는
    project가 가리키는 디렉터리 기준 POSIX 상대 경로. 스캔 범위는 영향 없음.
    폴백 limitation을 실은 문서도 조인 규칙은 동일(진단 표출은 소비자 선택).
    project는 절대 realpath이므로 조인은 한 working copy 안에서 성립(다른
    체크아웃 간 불일치는 결함이 아닌 범위 밖 속성). bridges limitations는
    사전순이 아닌 생산자 고정 순서(workspace 항목이 맨 뒤).
  - **후속 종결(2026-09-09)**: isthmus가 위 의미론으로 GRAPH-EXCHANGE 정본을 갱신했다
    (isthmus PR #36 `601dcdea0` realpath 정규화 + #37 `8d04dfd74` 모노레포 조인 루트
    선언 — cartograph `--project`도 포섭). dartograph는 isthmus를 임의 수정하지 않았고
    (소유자/조율 경로), issue #38는 양측 종결로 close 됐다(현재 상태는 Blockers 정본).

### 이전 세션 (0.4.0 릴리스 + Tier 2 흡수, PR #13~#37)

- 0.4.0(PR #36, `811bdff`): Tier 2 흡수 4건 — `affected`(#31)·`graph --format html`(#32)·
  `graph --level`+`--collapse`(#33)·`// dartograph:ignore`(#34) + operator usage-edge
  오탐 수정(#30) + GLM 후속 2건(#29) + 이전 세션 parity 3기능(#24~#26) + backlog(#21).
- external-retentions는 GRAPH-EXCHANGE 계약상 **구현 불가 확정**(#27 — 재조사 금지).
  extension type `.values` 공백은 **없음 확인·닫음**(언어가 ==/hashCode 선언 금지,
  인터페이스 디스패치는 overrideContract 보존).
- 0.3.0(#18·#19, `92826d0`) 및 그 이전 기록은 CHANGELOG·git 이력 참조.

## Key Files & State

- `lib/src/export/graph_exporter.dart`: 클래스 문서의 **제어문자·escape 정책 표가 정본**
  (JSON 계열/DOT/Mermaid/HTML/text/GH/SARIF uri + 신뢰 고정 어휘 목록). `_escapeMermaid`
  8문자(`#`→`#35;` 선행, `&<>`, `\`→`#92;`, `"`→`#quot;`, CR·LF→`#13;`·`#10;`),
  `_escapeForScriptTag`(`<`→`\u003c`), html(nodeLimit 400, degree 랭크, truncatedFrom).
- `lib/src/export/dead_reporter.dart`: `_escapeText`(C0·DEL 가시), `_githubEncode`(rune 기반,
  C0·DEL·C1·U+2028/9·bidi, 대문자 hex), `_sarifUri`(pathSegments), region은 line 있을 때만,
  json `report` 필드, GH 억제 notice(suppressed>0만).
- `lib/src/cli/dartograph_cli.dart`: `runDartograph` = `_dispatch` + `on Object` 최후 방어.
  `_changedContains`(since·affected 공통 양방향 링크 매칭 — dead는 null→보존, affected
  씨앗은 null→비매치로 **의도적 비대칭**, 주석 참조). `_reportBaselineWriteFailure`,
  bridges FormatException 별도 진단. help에 html·level/collapse·affected·ignore 문단.
- `lib/src/cli/changed_files.dart`: `decodeChangedFilesOutput` 순수 함수(비-UTF8 →
  ChangedFilesException), since 출력 계약 doc(toplevel 기준 normalize 절대경로).
- `lib/src/index/analyzer_graph_index.dart`: `_analysisInputFiles` 루트 전체 열거
  (`skipHiddenDirectories` — 숨김 디렉터리 가지치기, 중첩 pubspec 통합 탐지),
  `_collectIgnoreClaims`·`_hasIgnoreClaim`(토큰 스트림 precedingComments + leading 가드 +
  3-offset + 변수는 감싼 선언), `_isIgnoreDirective`(본문 시작 마커, `///`·블록 제외),
  entry-points limitation, `_cacheIdentity = v5-inline-ignore`(toolVersion 포함 — 릴리스마다
  자동 무효), plugin 루트 putIfAbsent.
- `lib/src/analysis/`: `affected_analyzer`(다중 씨앗 BFS·path/depth·unattributedSources),
  `graph_projection`(GraphLevel·전이 닫힘 `_containerOf`·collapse 세그먼트),
  `reachability_analyzer`(`isReachable`·`reachableMemberOf` 지연 색인 — witness는 정렬 순
  putIfAbsent로 기존 firstOrNull 동치), `layer_rules`(평가기별 `_globCache`),
  `graph_comparison`(loss당 색인 사용·limitations hoist), symbol_query·cycle_detector·
  architecture_metrics·baseline.
- `tool/benchmark_index.dart`: 파이프라인 A/B 하네스(7종 산출물 sha256·run별 해시 대조·
  반복 최소값·usage 가드). 성능 변경의 출력 동등성 정본.
- `lib/src/core/`: `code_graph`(nodes/edges 뷰 캐시+addNode/addEdge 무효화 — 중복 간선은
  GraphEdge 값 동등성으로 무효화 생략, 주석), graph_node(가드 4종+==/hashCode 테스트됨),
  graph_edge(`compareGraphEdges` 공유 비교자), graph_snapshot(간선 toSet dedup — P7 보류),
  fact_cache, retention_reason(`inlineIgnore` 포함 8값).
- 문서: README.md(영어 정본)·README.ko.md, CHANGELOG.md(영어)·CHANGELOG.ko.md,
  SECURITY.md(심볼릭 링크 채널), doc/USAGE.md(affected·html·level/collapse·ignore·
  entry-points limitation·결정성 예외 2종), CONTRIBUTING(영어 정본 규칙·릴리스 체크리스트),
  lib/AGENTS.md(결정성 예외), doc/RESEARCH.md(Tier 2 마감·미채택 처분).
- 테스트: 253개. 신규 계열 — test/export 제어문자 골든, test/cli/audit_gap_cli_test,
  test/cli/bridges_project_test(공유 루트 9케이스),
  affected_cli_test·graph_level_cli_test, fact_cache_test의 비표준 디렉터리 stale 회귀,
  changed_files decode 회귀, symlink 양방향 회귀(adoption·affected).

## Important Context / Decisions

- Facts:
  - **감사에서 견고 확인(재도출 금지)**: 캐시 오염 불가(sha256 디렉터리·hex 키 검증),
    snapshot 방어복사 실재, fact_cache fail-closed 3중 방어 + I/O 전후 키 재검사, git 호출
    구성(인자 리스트·--end-of-options·NUL·diff.relative 고정), batch 제한, entry_points
    fail-closed 검증, GH property escape 순서, 결정성 정렬 경로 전반, reachability BFS
    인접 1회 구축, agent_skill 주장-코드 일치.
  - 출력 주입의 뿌리는 **제어문자 정책 부재**였고 정책 표로 통일됐다. 새 출력 표면을
    추가할 때 policy 표 확장 없이 동적 값을 보간하지 않는다.
  - 캐시 키는 "해석 클로저의 보수적 상위집합"이다: 루트 안 전체 .dart(숨김 디렉터리
    제외) + 설정 + package_config + 의존 패키지 lib + SDK(Platform.version). 루트 밖
    상대 import만 미커버(문서화). 근본 해소는 해석 입력 목록을 페이로드에 싣는
    의존성 추적 캐시(설계 변경, future work).
  - since/affected의 링크 매칭은 양방향이고 dead(보존 편향)와 affected(오보 방지 편향)의
    null 처리가 의도적으로 다르다 — 통합 시 주석의 근거를 먼저 읽는다.
  - `Error` 계열 최후 방어는 계약(0/1/2/64·경로 미반향)이 디버그 관측보다 우선이라는
    결정이다. 상세 분류는 명령별 catch가 담당한다.
  - staleness(mtime)·bridges generatedAt은 **선언된 결정성 예외 2종**(USAGE 정본).
  - operator·ignore·level 등 0.4.0 사실들은 CHANGELOG 0.4.0/0.4.1과 git 이력 참조.
- Assumptions:
  - Mermaid 엔티티 코드·`Uri(pathSegments:)`·analyzer 토큰 스트림 계약은 1차 출처/실측
    확인(2026-09-08/09). 렌더러 버전별 차이는 미실측.
  - HANDOFF 검증 수치는 기록 시점 기준이다.

## Verification

- 이번 세션(PR #39~#46): 각 PR마다 format·analyze clean, 전체 테스트(228→244), 커버리지
  최종 **95.89%**(≥90), corpus 양방향·cli-contract 55케이스·clean git dry-run 0.
  8개 PR 모두 두 SDK CI green 후 머지. GLM packet-review 이번 세션 9회 — 전부 차단 없음
  (이전 세션 #33 B1·#34 B1~B3 차단은 재현·수정·핀 추가 후 머지됐고 0.4.0에 포함됐다).
- 0.4.1 릴리스: publish 성공 → 태그=게시 커밋(`53a4e0f`) → 전파 ~7분(재시도, 재게시 없음)
  → 새 격리 캐시 설치본으로 버전·report 필드·Mermaid 엔티티·계약 55케이스 검증 →
  pub.dev API latest 0.4.1 확인.
- 0.5.0 릴리스(PR #54): 253 테스트·contract 59·corpus·dry-run 0, 두 SDK CI green 후
  머지. publish 성공 → 태그 v0.5.0=게시 커밋(`16b18fd`, `--target`) → GitHub Release
  (바이트 변경 지점 요약 포함) → 전파 ~4분 후 새 격리 캐시 설치본으로 버전·workspace
  감지(project=모노레포 루트·`packages/pkg/lib/c.dart` 재기준)·override 0·containment
  위반 64·계약 59케이스 검증 → pub.dev API latest 0.5.0 확인.
- 성능 PR #48~#50(0.4.1 이후): 하네스 A/B — 인덱싱 min 1456→1053ms(-28%), query 배치
  10.7→1.7ms(-84%), rules 10.8→3.0ms(-72%), analyze 5.7→4.7ms. 7종 산출물 해시 전후
  동일 × 3 PR. 244 테스트 무수정·커버리지 95.89%·corpus·contract·dry-run 0. GLM 3회
  리뷰 전부 차단 없음(비차단: 하네스 run별 해시·반복 최소값 보강, addEdge 무효화 근거
  주석, 메모 누락 assert — 반영).
- bridges 공유 루트(PR #52): 신규 CLI 테스트 9종(workspace 감지·재기준·동일 project
  문자열·폴백 limitation 2종·동일 루트·우선순위·위치 자유·misuse 6+빈 값), 전체 253
  테스트·커버리지 95.89%·corpus·contract(bridges 4케이스 신규)·dry-run 0, 두 SDK CI
  green. GLM 리뷰: 차단 B1(CHANGELOG 항목이 0.4.1 절에 삽입) 수정, 비차단(빈 값 거부·
  limitation 목록 핀·메시지 귀속·containment ArgumentError·help 문구·테스트 갭 3) 반영.
  isthmus 설치본 왕복: project 일치 조인 성공(evidence 재기준 경로 보존) + 불일치 거부.
- 후속(0.5.0 이후): PR #57(issue #38 close — docs 전용)은 isthmus GRAPH-EXCHANGE 문구
  갱신(isthmus PR #36/#37)을 API로 확인 후 마감 코멘트(issuecomment-5602011319)+
  close(reason: completed), 두 SDK CI green. PR #58(죽은 공개 API 처분) format·analyze
  clean, 253 테스트(usageEdgesFrom 테스트 −1·deadDeclarations 스모크 +1 = 순증 0),
  커버리지 **95.98%**, 자기 패키지 `dead .` 0 findings, corpus·cli-contract·clean git
  dry-run 0 경고, benchmark_query identicalResults 참, 두 SDK CI green. GLM packet-review
  차단 없음(비차단 4건 중 getter 불변화·doc 일반화 반영, DeadFinding primitive·패킷 밖
  잔존 없음은 코드/grep으로 검증됨).
- 로컬 커버리지: 전용 포트 + `format_coverage -i`(플래그 주의). check-analyzer-boundary는
  로컬 rg 부재로 CI 위임.

## Blockers & Open Questions

- 필수 제품 작업 없음. 열린 제품 PR 없음.
- **issue #38 — 양측 완전 종결·close 완료(2026-09-09, reason: completed)**:
  dartograph 측 (a)+(b) 구현·왕복 검증·0.5.0 릴리스(PR #52) + 의미론 코멘트
  (issuecomment-5599285065), isthmus 측 GRAPH-EXCHANGE 정본 갱신 완료 — isthmus
  PR #36(`601dcdea0`, project realpath 정규화 명문화) + PR #37(`8d04dfd74`, 모노레포
  조인 루트 선언 명문화; "생산자 선언 조인 루트" 정의로 cartograph `--project`(분석
  루트 자체)와 dartograph 재기준화 옵션을 모두 포섭, isthmus 코드 무변경·소비자
  fail-closed 유지). issue 본문이 요구한 두 합의(realpath 문구 + 공유 루트 선언
  방식)가 양측 반영됐고 왕복 실측(dartograph#38·#52)으로 조인 확인 → 마감 코멘트
  (issuecomment-5602011319) 후 close. **자매 저장소는 소유자/조율 경로로만 갱신됐고
  dartograph가 isthmus를 임의 수정한 적 없음(금지 유지).** 남은 비차단 후속(workspace
  멤버십 검증·`unscanned-*` 복수형 문구)은 Next Steps 4의 감사 낮음 항목으로 이관.
- external-retentions 구현 금지(GRAPH-EXCHANGE 계약, PR #27) 유지.

### 남은 감사 backlog (2026-09-08/09 감사의 미처리분 — 근거는 위 기록과 PR 본문)

- **성능: P1~P6·P8~P10은 #48~#50으로 완료(측정·해시 동일성 포함)**. 남은 것은
  **P7(GraphSnapshot factory의 이미-Set인 간선 toSet 재해싱)뿐 — GLM "측정 결과가
  근거 없으면 보류 명시" 판정대로 보류**(공개 factory의 방어적 중복 제거를 빼는
  변경이라 이득 측정 없이 손대지 않는다). 재착수 시 하네스로 측정부터.
  향후 심화 후보(기록): 세션 범위 _idMemo 공유(이득 미미 판정), allNodeIds prefix
  이진 탐색(측정상 불필요 확인 시까지 보류), 의존성 추적 캐시(루트 밖 상대 import
  커버 — 설계 변경).
- **죽은 공개 API 처분 — 완료(PR #58, 정책 A 최소화·hygiene)**: `querySymbol` 제거
  (unexport만 하면 자기 패키지 `dead` 검사에서 "보존 루트 도달 불가"로 잡힘을 실측 →
  함수 삭제 + benchmark_query에 동치 인라인, identicalResults 참 유지), `usageEdgesFrom`
  제거(CodeGraph 공개 메서드·제품 호출 0·test만), `ReachabilityResult` 누출 해소
  (공개 필드 `analysis`를 private `_analysis`로 좁히고 `List<DeadFinding> get
  deadDeclarations`(불변)만 공개, 배럴은 `DeadFinding`만 export; ReachabilityResult·
  ReachabilityExplanation은 내부 유지). CLI 출력·종료코드 무변경, 스모크 테스트로
  공개 표면 고정(배럴 import로 DeadFinding 이름 사용=export 증명 + 위임 내용 + 불변),
  커버리지 95.98%, GLM packet-review 차단 없음(비차단 getter 불변화·doc 일반화 반영,
  DeadFinding primitive·잔존 없음은 코드/grep 검증). **미릴리스 — 다음 릴리스 때 기록.**
- **낮음/기록**: html `_htmlKind`의 `::` 포함 파일명 오분류, `_path`의 `project:` 센티널
  충돌(합법 파일명 `project:x.dart`), SARIF rules 배열의 testOnly×file 잠재 불일치
  (현재 vacuous·주석 고정), SARIF Windows 절대경로 fallback의 `file:///` 표준화 후보,
  bridges 동적 이름 toSource 개행 시 전체 문서 실패(GRAPH-EXCHANGE dynamic:true 보존
  원칙과 긴장 — isthmus 조율 사안), bridge limitations 미정렬(생산자 고정 순서라 결정성
  유지), graph_exporter limitations 미dedup(CLI가 선행 dedup), bridge_index 스코프 방문자
  39줄 미행사(감사 T4 — catch/for/지역함수/클로저/채널 재대입, fixture 보강 후보),
  cli 잔여 57줄(희귀 분기), `<no-library>` 파일 수준 합류(의도·문서화됨). 감사 T6
  (graph_projection:43·cycle_detector 방어 분기)은 도달불가/무해 확인 — 재도출 금지.
- **vacuous 확인(재도출 금지)**: dead findings 정렬 키 위치 무시(kind+id 동일·위치 다른
  finding은 ID 유일성으로 불가), mermaid 간선 null(snapshot endpoint 검증), N2/N4.

### 검토 후 닫은 항목·보류 항목 (이전 세션 근거 유지)

- 닫음: extension type `.values` 공백(없음), GLM 후속 2건(#29), bridges limitation "보강",
  대형 모듈 분리, `.pubignore` 유출 주장, html 터치 입력·색상 범례·rAF 상시 draw
  (cartograph parity 범위), collapse 잘린 간선 수(중복 계수), 캐시 키 pubspec.lock/
  .pubignore(analyzer 입력 아님).
- 보류: package:args, isolate 병렬화(대형 체크아웃 측정 필요), melos(PRD v0.2+),
  EventChannel·BasicMessageChannel fact화(isthmus 조율 없이 금지), Tier 3/4 흡수 후보
  (RESEARCH 정본 — 새 요청 시 PRD/PLAN에서 범위 결정).

## What Worked / Avoid

- **성능 수정은 A/B 하네스 + 산출물 해시로 "출력 동일"을 증명한다**: 벤치는 상대
  비교만 의미 있고(SLA 아님), 첫 run은 JIT 워밍업이라 최소/중앙값을, 1회 측정은
  노이즈라 반복 최소값을 쓴다. 해시 동등성 + 기존 골든 무수정 통과가 최적화의
  안전망이다(측정 없는 최적화 금지 규칙의 운영 형태).
- **감사는 다중 소스 + 전수 재검증**: 하위 에이전트·GLM 지적을 그대로 믿지 않고 실측
  (개행 파일명 주입, SARIF Uri 손상, stale hit, symlink retarget)·코드 대조로 확인했다.
  GLM이 찾은 차단 4건(#33 B1·#34 B1~B3)도 재현 후 수정 — 리뷰 출력은 근거일 뿐이다.
- **analyzer API는 프로브 스크립트로 실측**(문서/기억 3번 빗나감: FieldDeclaration
  fragment null, doc comment 시 precedingComments 이동, 첫 토큰 previous=EOF 센티널
  offset -1). 프로브는 저장소 루트에 임시로 만들고 **삭제**한다(패키지 밖 스크립트는
  package: 해석 실패).
- **push는 ls-remote로 확인**: `git push ... | tail -1`이 실패를 삼킨 경우가 여러 번
  (config 쓰기 경고·빈 출력). PR head sha와 로컬 HEAD를 대조한다.
- **샌드박스 GH 토큰의 기본 스코프는 issues 쓰기가 없다**(403 — PR 생성·머지는
  가능). 소유자가 권한을 부여하면 게시된다(0.5.0 세션에서 실증). 막혀 있는 동안은
  내용을 저장소 안(HANDOFF·PR 본문)에 보존하고 사용자에게 보고한다.
- **기능 브랜치를 만들기 전에 커밋하지 않는다**: bridges 작업을 local main에 커밋했다가
  `git branch -f main origin/main` + upstream 재설정으로 복구했고, `git push -u origin
  main:refs/heads/...`가 main의 upstream을 오염시킬 수 있음을 확인했다(-u 남용 금지).
- **gh release create의 positional sha는 에셋 glob**으로 해석된다 — `--target <sha>` 사용.
- **python 치환은 dart format 후에 앵커가 어긋난다** — 편집 전 현재 본문을 읽고, 포맷된
  텍스트에 대해 edit 도구를 쓴다(heredoc+python은 따옴표·백틱 충돌이 잦다).
- **한국어 산문에 한자·일본어 혼입 반복**(이번 세션 6회+) — 커밋·문서 작성 후 CJK 스캔
  (`[\u3040-\u30ff\u4e00-\u9fff]`)을 습관화한다. push 전이면 amend, 후면 후속 커밋.
- **미커밋 작업의 브랜치 확인**: D·E 작업을 선행 PR 브랜치 위에서 시작해 stash 이동을
  2번 반복했다. 새 작업 시작 전 `git branch --show-current`.
- **dry-run은 clean git에서만 경고 0** — 미커밋 변경 자체가 경고다.
- packet-review는 시간당 6회 — 다중 PR 세션은 페이싱하고, 리뷰어 권장의 기계적 구현
  delta는 재전송을 생략할 수 있다(사유 기록).
- 샌드박스: rg 없음(bash grep, boundary 게이트는 CI), Write 도구는 워크스페이스 밖 거부
  (PR 본문은 bash heredoc), 커버리지는 전용 포트, macOS는 비-UTF8 파일명·`::` 파일명
  생성 가능(개행 파일명도 가능 — 주입 테스트에 활용).
- **반쪽 수정 금지 / 게이트별 exit code 개별 확인 / Directory.current 프로세스 전역 /
  상대 경로 파일 쓰기 오염 주의 / 실패 재현은 올바른 기준 커밋에서 / main 직접 커밋
  금지 / 기본값 출력 보존은 회귀로 고정** — 계속 유효.

## Next Steps

1. 실제 branch/status/log를 확인하고 루트 및 작업 경로 AGENTS.md를 읽는다.
2. 지금까지 완료: PR #39~#54(+docs #47·#51·#53·#55·#56) — **0.4.1·0.5.0 릴리스 +
   성능 backlog(P1~P6·P8~P10) + issue #38 dartograph 측**, 이어서 PR #57(issue #38
   양측 종결·close) + PR #58(죽은 공개 API 처분). 완료된 구현·감사·측정·릴리스·처분을
   반복하지 않는다. **미릴리스 누적은 PR #58 하나**(CHANGELOG `Unreleased` 절 없음 —
   릴리스 때 기록; Current Status 참조).
3. **issue #38 완전 종결·close 완료(2026-09-09)** — dartograph 측(PR #52, 0.5.0
   릴리스 + 코멘트 issuecomment-5599285065)과 isthmus 측 GRAPH-EXCHANGE 문구 갱신
   (isthmus PR #36 realpath + #37 조인 루트, 둘 다 merge)이 모두 끝났다. isthmus
   저장소는 소유자/조율 경로로만 갱신(임의 수정 금지 유지). 재개 시 issue가
   closed인지 API로 확인.
4. **다음 세션 이월분(우선순위 제안 — 전부 근거·선행 조건이 위 Blockers/backlog 목록에
   있다, 재도출 금지)**:
   a. P7(GraphSnapshot toSet 재해싱) — 재착수 시 하네스 측정부터(보류 판정 기록됨).
   b. bridge 스코프 방문자 테스트 보강(catch/for/지역함수/클로저/채널 재대입 39줄).
   c. 감사 낮음 항목들(html `::` 파일명 오분류, `project:` 센티널 충돌, SARIF Windows
      fallback, bridges toSource 개행 정책=GRAPH-EXCHANGE 조율 사안, workspace 멤버십
      검증, `unscanned-*` 복수형 문구).
   d. 새 흡수 범위 = RESEARCH Tier 3/4(yaml 확장·init·markdown/codeowners 리포터·
      issue-type 필터·MCP / metrics zone 라벨·순환 색칠 등) — 사용자 요청 시 PRD/PLAN에서
      범위 결정.
5. 다음 릴리스도 지시 시에만: **미릴리스 누적 PR #58(죽은 공개 API 처분 — CLI 무변경·
   라이브러리 API 표면 변경)을 두 언어 CHANGELOG에 기록하고 semver를 판단한 뒤**, 버전
   정합 6곳 + (Korean) 표기 규약, clean git dry-run 후 publish → `--target`으로 같은 커밋
   태그+Release → 전파 대기(분 단위, 재시도) 후 새 캐시 설치본 검증. 동일 버전 재게시 금지.

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/dartograph`, read `HANDOFF.md` and applicable
`AGENTS.md` files, then continue from: `Verify current Git state. Product 0.5.0 is released
(pub.dev latest 0.5.0 with ENGLISH README/Changelog, tag v0.5.0 at 16b18fd = publish commit,
GitHub Release, fresh-cache install verified incl. bridges workspace detection and the 59-case
CLI contract; 0.4.1 was the audit-fix release before it). This session
converted README/CHANGELOG to English originals with Korean twins (README.ko.md/CHANGELOG.ko.md,
.pubignore-excluded; CONTRIBUTING owns the twin-sync rule), ran a FULL codebase audit (structure/
performance/security/correctness/test-gaps; method: direct review + 3 explore agents + 3 GLM
cross-check packets, every major claim empirically re-verified), and merged six audit-fix PRs:
#40 control-character/injection policy across all output surfaces (mermaid newline statement-splitting
was a measured injection; SARIF Uri(path:) corrupted backslash/percent paths; policy table now lives
in graph_exporter class docs), #41 CLI Error boundary (on Object last resort, exit-255/stack-trace
leak closed) + bridges/git-UTF8 attribution, #42 cache-key resolution-closure coverage (stale hit
reproduced via tool/ helper rename; whole-root enumeration with hidden-directory pruning for .fvm),
#43 output fidelity (dead json report field, GH suppression notice, conditional isEnumConstant,
SARIF region invention removed, staleness mtime declared as determinism exception), #44 symlink
bidirectional matching for --since/affected + entry-points narrowing limitation + SECURITY symlink
channel, #45 test-gap regressions (coverage 94.4→95.9%). Then 0.4.1 was released bundling all of it
(user-approved). AFTER the release, the measured performance backlog was completed too (user order
"1번 ㄱㄱ"): new A/B harness tool/benchmark_index.dart (synthetic dep-free 600-file package, 7
artifact sha256 pins output equality, per-run hash cross-check), then #48 indexing -28% (P1
element→ID memo, P2 CodeGraph cached read views + export-loop hoist, P9 shared edge comparator,
P10 single pubspec read/source computation), #49 query batch -84% (P3/P6 ReachabilityResult
isReachable/reachableMemberOf indexes, P5 double-sort removal, compare limitations hoist), #50
rules -72% (P4 per-pattern glob RegExp cache, P8 unique-source symlink resolution memo for
--since). All three: hashes identical, 244 tests unmodified. THEN issue #38 was handled (PR #52):
bridges --project <shared-root> + pub workspace auto-detection (see Completed/Blockers for the
isthmus contract semantics; round-trip verified against installed isthmus 0.2.0 BOTH directions).
The issue comment with the contract semantics WAS posted after the owner granted issues write
scope (issuecomment-5599285065). Then **0.5.0 was released** (PR #54, semver minor for the new
bridges option; pub.dev latest 0.5.0, tag v0.5.0 at 16b18fd = publish commit, GitHub Release,
fresh-cache install verified incl. workspace detection and the 59-case contract). AFTER 0.5.0 two
follow-ups merged: PR #57 (docs: issue #38 closed on both sides) and **PR #58 (dead public API
disposition, policy A minimize+hygiene)** — querySymbol removed (unexport ALONE trips the self-`dead`
gate as "unreachable from all retention roots", so the function was DELETED and benchmark_query
inlines the equivalent `SymbolQuerySession(...).query(name)`, identicalResults stays true),
usageEdgesFrom removed (CodeGraph method, product-unused/test-only), and the ReachabilityResult leak
fixed (SymbolQuerySession.analysis made private `_analysis`; the only public surface is
`List<DeadFinding> get deadDeclarations` (unmodifiable); the barrel now exports just DeadFinding;
ReachabilityResult/ReachabilityExplanation stay internal). CLI output/exit codes UNCHANGED, coverage
95.98%, GLM packet-review no blocking (2 non-blocking applied: getter unmodifiable + doc). **PR #58 is
MERGED but UNRELEASED** — lib/ API surface changed, CLI did not; record it at the next release
(CHANGELOG has no Unreleased section by convention). PR #57 was HANDOFF-only (.pubignore-excluded),
so PR #58 is the ONLY unreleased accumulation.
REMAINING: P7 (snapshot toSet rehash) is DELIBERATELY DEFERRED
— measure first if revisiting; bridge scope-visitor test coverage (39 lines);
issue #38 (isthmus bridges --project / pub-workspace shared root) — FULLY CLOSED on BOTH sides
(2026-09-09): the dartograph side is DONE and RELEASED in 0.5.0 (PR #52: bridges --project
<shared-root> + pub workspace auto-detection with fallback limitations, isthmus-installed round-trip
verified both directions; contract semantics posted as issuecomment-5599285065), AND the isthmus-side
GRAPH-EXCHANGE wording was updated via isthmus PR #36 (project realpath normalization) + PR #37
(monorepo join-root declaration, a producer-declared "join root" definition covering BOTH cartograph's
--project (the analysis root itself) and dartograph's re-basing option; no isthmus code change,
consumer exact-string fail-closed preserved), so the issue was CLOSED (reason: completed, closing
comment issuecomment-5602011319); do NOT touch the isthmus repo itself (it was updated only via the
owner/coordination path); external-retentions stays contract-blocked (PR #27);
Tier 3/4 absorption candidates live in doc/RESEARCH.md. Audit no-issue confirmations and vacuous
findings are listed in HANDOFF — do not re-derive. The session is CLOSED: everything deferred to
the next session is enumerated in Next Steps item 4 (P7 measurement-first, bridge scope-visitor
tests, audit low items, Tier 3/4).
Follow the next explicit user task.`

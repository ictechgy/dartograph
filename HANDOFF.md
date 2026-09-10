# Handoff

_Last updated: 2026-09-10 (0.7.0 릴리스 완료 — PR #78: 미릴리스 6건[#69, #71~#75] 일괄 발행, semver minor. 릴리스 기준 v0.7.0 → e1b3202. pub.dev latest 0.7.0, GitHub Release 완료, 새 격리 캐시 설치본 검증 완료. 미릴리스 누적 0건. 다음 세션 이월분 = Tier 3 범위 결정뿐)_

## Goal

- 영구 무료 MIT Dart/Flutter 근거 질의 CLI를 유지한다.
- **이번 세션(0.7.0 릴리스, PR #78)**: 미릴리스 누적 6건(#69 bridges 문법 수정, #71 GraphNode isLibrary·캐시 v3, #72 metrics zone, #73 dot 순환 색칠, #74 graph --format anon, #75 dead --report-redundant-public)을 **semver minor(0.7.0)**로 발행하고, pub.dev 게시·태그·GitHub Release·새 격리 캐시 설치본 검증을 완료했다.
- 직전 세션(감사 낮음 처분 + GraphNode kind + Tier 4, PR #69~#76): ① bridges 개행 실패 현행 유지 종결, ② `unscanned-*` 복수형 문구 수정(#69), ③ GraphNode isLibrary(#71), ④ Tier 4 4종(#72~#75) 흡수.
- 이전 세션(PR #57~#68): issue #38 close(#57), 죽은 API 처분(#58), README 퇴고(#65), 0.6.0 릴리스(#66).

## Current Status

- 릴리스 기준: **`v0.7.0` → `e1b3202`** (PR #78 merge = 게시 커밋). pub.dev latest 0.7.0
  (Readme·Changelog 탭 **영어**)·GitHub Release(tag=v0.7.0) 공개. 새 격리 캐시 설치본으로
  `--version` 0.7.0·CLI 계약 62케이스 검증 완료. (이전 0.6.0→`85c345a`, 0.5.0→`16b18fd`, 0.4.1→`53a4e0f`.)
- main 기준: **PR #78(0.7.0 릴리스)** + PR #69~#76(감사 낮음 처분 2건 + GraphNode isLibrary + Tier 4 4종 + 세션 기록) + 0.6.0 릴리스(#66). 열린 제품 PR 없음.
- **미릴리스 누적 0건** (0.7.0으로 전량 발행 완료).
- 테스트 288개, 라인 커버리지 **97.15%**(감사 전 94.4%).
- 지침 기준: `c4d121d` (PR #7 merge). 정본은 루트 AGENTS.md, 하위 규칙은 lib·lib/src/index·
  test·fixtures·tool·doc. **pub.dev 노출 문서(README·CHANGELOG)는 영어가 정본이고
  `.ko.md` 쌍과 내용을 동기화한다(CONTRIBUTING 정본 규칙).**
- 제품 배포 blocker 없음. HANDOFF가 Git 상태보다 우선하지 않으므로 재개 시 실제 상태 확인.

## Completed

### 이번 세션 (0.7.0 릴리스, PR #78)

- **0.7.0 릴리스(PR #78, 2026-09-10)**: 미릴리스 누적 6건(#69, #71~#75)을 semver minor로
  발행. 신규 CLI 표면 2개(`graph --format anon`, `dead --report-redundant-public`)와
  덧셈 필드(`metrics` zone), dot 순환 색칠, GraphNode `isLibrary` 플래그 및 캐시 스키마 v3.
  - **버전 정합 6곳**: `pubspec.yaml`, `lib/src/core/tool_info.dart`(toolVersion 0.7.0),
    `doc/USAGE.md`(2곳 0.7.0), `SECURITY.md`(0.7.x 지원 창), `test/cli/dartograph_cli_test.dart`
    (`--version` 단언 0.7.0).
  - **CHANGELOG 두 언어 정합**: `CHANGELOG.md`(영어 정본) 및 `CHANGELOG.ko.md`(한국어 쌍둥이)에
    0.7.0 섹션 작성 및 완전 동기화.
  - **GLM 릴리스 리뷰 반영**: 차단 B1(redundant-public 옵션 결합 계약 정정: `--explain`·
    `--baseline`·`--report-test-only`와 결합 금지 usage 64, `--since` 및 머신 리더블 포맷 허용),
    B2(GraphNode 직렬화 스키마 v3 증가, 캐시 identity 불변 명시), 비차단 N1/N4/N5(관용 어휘
    화이트리스트 표기, `metrics` JSON 출력 표현, 한국어 어휘 일원화) 반영.
  - **게시 및 검증**: clean git dry-run 0 경고 확인 → `dart pub publish --force` 업로드 성공
    → 태그 `v0.7.0`=게시 커밋(`e1b3202`) 생성·푸시 → GitHub Release 생성 → pub.dev API latest 0.7.0
    확인 → 새 격리 캐시(PUB_CACHE) 설치본으로 `--version` 0.7.0 및 CLI 계약 62케이스 통과 실측.

### 직전 세션 (감사 낮음 이월 2건 처분 + GraphNode kind + Tier 4 흡수, PR #69~#75)

- **① bridges 동적 이름 toSource 개행 시 전체 문서 실패 — 판단 완료·현행 유지로 종결**:
  프로브 실측(리터럴 `\x01` 이스케이프·멀티라인 리터럴·toSource 개행 3케이스 전부 exit 2
  "Bridges extraction failed"; 개행 없는 동적 이름은 정상 방출 dynamic:true — toSource가
  줄바꿈을 공백으로 접는 건 대조군으로 확인) + GRAPH-EXCHANGE 대조(이름 제어문자 금지가
  생산자 의무이고 project 필드의 "소비자에게 거부될 문서를 내보내지 않는다" 논리와 동일한
  fail-closed; USAGE.md가 0.3.0부터의 동작으로 이미 문서화) → 사용자 결정: **현행 유지**.
  완화(per-fact skip + 신규 limitation)는 소비자가 세는 dynamic fact 수가 달라지는 교환
  의미론 변경이라 isthmus 조율 없이 금지 유지. **새 요청·isthmus 제안이 없는 한 재론 금지.**
- **② `unscanned-*` 복수형 문구 — 완료(PR #69, 3개 family 일괄)**: 감사 지적분(unscanned-* N≥2
  복수형 누락)과 실측 중 발견한 dynamic-* N=1 문법 결함(`1 method invocations use`·
  `1 channel constructors use`)을 함께 정리. 나머지 family 형식과 동일한 삼항식. N≥2 dynamic-*·
  N=1 unscanned-* 문자열 바이트 불변, 테스트 핀 1개 갱신(dynamic-method-names N=1). 검증:
  format·analyze clean, 269 테스트, 커버리지 97.04%(불변), corpus·cli-contract·dry-run 0,
  프로브로 N=2/N=3 렌더링 확인, 저장소 전역 grep으로 외부 참조 없음 확인. GLM packet-review
  차단 없음(비차단 — diff 범위 실측 확인, 신규 분기 핀은 CONTRIBUTING "문구 복제 금지"로 기각,
  패킷 밖 소비자는 grep 실측 없음, 버전 bump는 limitations가 검증 제외 자유 문장임으로 기각).
  두 SDK CI green 후 머지(`15c4b21`). HANDOFF 전사 docs PR #70(`9811a3d`).
- **③ GraphNode 명시 isLibrary — 완료(PR #71)**: 감사 낮음 후속 후보였던 kind threading.
  html 종류·이름 판정이 id 모양 `.dart::` 유추를 버리고 명시 플래그로. 모순 가드 확장,
  캐시 schemaVersion 2→3(isEnumConstant 선례 — identity 불변), collapse 집계 정점은
  라이브러리 표시·atLevel 폴백은 선언 기본, json·dot·mermaid 무변경. 실측 대조: 실제
  패키지에서 차이는 휴리스틱이 못 가르던 `.dart::` 파일명 케이스 하나뿐(수정 전 member
  오분류·이름 절단 → 수정 후 library 정확 분류). GLM 차단 없음(비차단 — 캐시 왕복·사영
  폴백 의미론 핀·주석 정리 반영; unnamed-extension kind 전환 주장은 실측으로 반박 — 실제
  어댑터 ID는 항상 라이브러리 한정이라 무변경). 머지 `4561f91`.
- **④ Tier 4(cosmetic) 4종 흡수 — 완료(PR #72~#75, 사용자 범위 선택 "Tier 4 먼저")**:
  - **metrics zone 라벨(#72)**: cartograph `MetricsZone` 패리티(1차 출처 Swift 원문 직접
    확인). 4종 영역(고립 별도 — D=1 고통 1위 왜곡 방지), 경계가 `--strict` 위반 판정과
    일치. GLM "차단"(고립 strict 모순 가능성)은 패킷 밖 CLI 코드 실측(`!item.isolated &&`)으로
    해소. 머지 `c0bc23e`.
  - **순환 노드 색칠(#73)**: madge 패리티. `graph --format dot`이 순환 참여 정점을 붉게
    (CycleDetector SCC·self-loop, exporter는 순수 직렬화). 순환 없는 그래프 바이트 불변.
    GLM 차단 없음(비차단 — CLI 비순환 무색칠 단언·속성 순서 문서화 반영). 머지 `092644c`.
  - **anon export(#74)**: dependency-cruiser `anon` 리포터 패리티. `graph --format anon` —
    json 문서 모양 유지·결정적 토큰 치환(s0, s1, …·단사·구조 보존·관용 어휘 whitelist).
    limitation 문구 치환은 다중 세그먼트 경로 전체만(과다치환 방지), 전체 키 교대 패턴 한 번
    패스(이중 치환 구조 차단). 도그푸딩: 자기 저장소 685정점 식별자 누출 0. GLM 리뷰어 머지
    조건(실제 limitation 통합 테스트) 포함 비차단 전부 반영. 머지 `622d382`.
  - **redundant public(#75)**: Periphery `redundant public accessibility` 패리티.
    `dead --report-redundant-public` — 살아 있는 공개 선언 중 사용 참조가 전부 자기
    라이브러리에서 시작하는 것을 info로(test-only와 같은 계약: finding 있어도 exit 0,
    --explain·--baseline·--report-test-only 결합 64). 보수적 제외: 보존 루트 전부·enum
    상수·override 이행 source·연산자(이름에 `_` 불가)·비공개 컨테이너 멤버(이름 전체
    세그먼트 검사)·`<` 마커. GLM 차단 3건 중 B3(비공개 컨테이너) 수정, B1(멤버 귀속)·
    B2(의존 스코핑)는 프로브 실측으로 기각(외부 멤버 호출의 멤버 정점 정확 귀속·의존
    무정점). 머지 `2e489e2`.
  - RESEARCH.md 원장에 Tier 4 → 구현 이행 기록(Tier 3만 잔여).
- 이 세션의 ①·② 처분은 docs PR #70으로, #71~#75 완료는 #76으로 전사했고 이어 세션 마감
  기록(Verification 보강·이월분 명확화)으로 닫는다.

### 이전 세션 (후속: issue #38 close + 이월 항목 + README 퇴고 + 0.6.0 릴리스, PR #57~#68)

이월 항목을 순차 소진했다(PR별 상세는 Verification과 각 PR 본문 참조).

- **issue #38 양측 종결·close(#57)**: isthmus 측 GRAPH-EXCHANGE 문구 갱신(isthmus PR #36
  realpath + #37 조인 루트, 둘 다 merge)을 API로 확인하고 dartograph 0.5.0 동작과 대조 →
  마감 코멘트(issuecomment-5602011319) + close(reason: completed). isthmus는 소유자/조율
  경로로만 갱신(임의 수정 금지 유지).
- **죽은 공개 API 처분(#58, 정책 A 최소화·hygiene)**: `querySymbol`(unexport alone은 자기
  dead 검사 위반 → 함수 삭제 + benchmark 인라인)·`usageEdgesFrom`(제품 호출 0) 제거,
  `ReachabilityResult` 누출 해소(`analysis`→private + `deadDeclarations` getter, 배럴은
  `DeadFinding`만 export). CLI 출력·종료코드 무변경.
- **P7 측정-보류 확정(#60)**: 고립 프로브(합성 Set<GraphEdge> 30회 최소)로 toSet 재해싱
  14726간선 24µs = 인덱싱 0.002% 측정 → negligible, 보류(제품 코드 무변경).
- **bridge 스코프 방문자 테스트 보강(#61)**: test/index/bridge_scope_test.dart 12케이스
  (catch/for/지역함수/클로저/재대입 + GLM 권장 섀도잉 + 인접 채널 경로), bridge_index
  미커버 40→9줄, 커버리지 97.03%.
- **감사 "낮음" 실행가능 subset(#63)**: SARIF uri 버그 수정(file:·package: pass-through,
  프로브 실측), html `::` 파일명 오분류(`.dart::` 휴리스틱), pub workspace 멤버십 검증
  (+`pub-workspace-member-not-listed`), `project:` 센티널 vacuous 문서화. 커버리지 97.04%.
- **README 퇴고(#65)**: 영문 README.md를 GLM packet-review 2회(차단 0·"pub.dev 발행 가능")로
  여러 패스 퇴고 + README.ko.md 쌍둥이 동기화. 사실 불변.
- **0.6.0 릴리스(#66)**: semver minor(0.x 공개 API 제거=파괴적). CHANGELOG 두 언어
  (breaking 마커 + 마이그레이션 힌트), 버전 정합 6곳, GLM 릴리스 리뷰 차단 없음, publish →
  태그 v0.6.0=게시 커밋(`85c345a`, `--target`) → GitHub Release → 전파 ~3분 → 새 캐시
  설치본 검증(--version·계약 59·workspace 멤버십 양방향).
- GLM packet-review 이번 세션 6회(제품 #58·#61·#63, README #65 ×2, 릴리스 #66) 전부 차단
  없음, 비차단 피드백 실측 대조 후 반영. docs 전용 전사(#57·#59·#60·#62·#64·#67)는 리뷰
  생략(사유 기록).

### 이전 세션 (영어 문서 + 전체 감사 + 수정 6건 + 0.4.1 + 성능 + bridges + 0.5.0, PR #39~#56)

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

### 지지난 세션 (0.4.0 릴리스 + Tier 2 흡수, PR #13~#37)

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
  graph_edge(`compareGraphEdges` 공유 비교자), graph_snapshot(간선 toSet dedup — P7 측정-보류),
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
- 후속 docs(PR #59·#60): #58 처분·미릴리스 누적과 P7 측정-보류를 HANDOFF로 전사, 두 SDK
  CI green(GLM 생략 — 검증된 사실 전사, 사유 본문 기록). P7은 고립 프로브(합성
  Set<GraphEdge> 30회 최소)로 14726 간선 toSet 24µs(인덱싱 0.002%) 측정 → 보류 확정.
- bridge 스코프 테스트(PR #61): 신규 test/index/bridge_scope_test.dart 12케이스(스코프 구성
  5 + 인접 채널 경로 3 + containment 1 + GLM 권장 섀도잉 3 — 선언 효과 단언). format·analyze
  clean, 265 테스트, 커버리지 95.98→**97.03%**, bridge_index 미커버 40→9줄, dead 자기검증 0,
  corpus·cli-contract·dry-run 0(테스트 전용·제품 코드 무변경), 두 SDK CI green. GLM
  packet-review 차단 없음(9 기대값 수동 트레이스 정확 확인; 핵심 비차단 — 선언 분기
  트래버스만·효과 무단언 → 섀도잉 fixture로 반영; 나머지 nit·범위 밖은 기록). 남은 9줄은
  vacuous/비실용: 165-168 비교자 동일-offset tiebreaker, 217 TOCTOU race, 718 resolved
  flutter InstanceCreation 필요, 833-835 조건부 re-export — 재추격 금지.
- 후속 docs(PR #62): item c 완료를 HANDOFF로 전사, 두 SDK CI green(GLM 생략 — 검증된 사실 전사).
- 감사 "낮음" 실행가능 subset(PR #63): 제품 코드 3건 수정 + 1건 vacuous 문서화.
  (1) SARIF uri 버그 실측(프로브: `_sarifUri`가 `package:app/x`→`package%3Aapp/x`,
  `file:///a`→`file%3A///a` 손상) → 원본 source의 project: 접두로 판정해 절대 URI는
  pass-through(GLM 제안 반영: root 수준 `file:x.dart` 파일명 잔여 충돌도 구조적으로 차단).
  (2) html `::` 파일명 오분류 → `.dart::` 판별자 휴리스틱(GraphNode 코어 변경 회피; 잔여
  `.dart::` 파일명·근본해결 kind threading은 후속 기록). (3) workspace 멤버십 검증(`workspace:`
  목록 명시경로 일치·글롭 보수 허용·미멤버 `pub-workspace-member-not-listed` limitation+폴백).
  (4) `project:` 센티널 충돌은 vacuous 확인(항상 prepend→한 번 strip 왕복, 주석 고정). 제외 2건
  (bridges toSource 개행=isthmus 조율, `unscanned-*` 복수형=출력 변경)은 별도 판단 보류.
  format·analyze clean, 269 테스트(+4 회귀), 커버리지 97.04%, dead 0, corpus·cli-contract·
  dry-run 0, 두 SDK CI green. GLM packet-review 차단 없음(4건 수용; 비차단 — SARIF 구조개선·
  html 멤버-in-`::` 테스트·정책 표 동기화·잔여 엣지 기록 반영, workspace nit은 fail-closed·
  병적 판정 무변경).
- README 퇴고(PR #65, docs-only): 영문 README.md를 GLM packet-review 2회(차단 0·"pub.dev 발행
  가능")로 여러 패스 퇴고(Install↔Usage 실행형태 통일, isthmus·GRAPH-EXCHANGE 소개+표기 통일,
  관용구·병렬성, compare·skill·--baseline 불릿 보강, 섹션 "Analysis limitations and guarantees"),
  README.ko.md 쌍둥이 동기화(구조·불릿 수 미러, 명령 불변). 사실 불변, CJK clean.
- 0.6.0 릴리스(PR #66): 미릴리스 누적 PR #58(라이브러리 API)+#63(감사 낮음 subset)+#65(README)를
  semver minor(0.x 공개 API 제거=파괴적)로 발행. 두 언어 CHANGELOG 0.6.0(breaking-change 마커 +
  마이그레이션 힌트 + workspace 3분기 정확화 — GLM 릴리스 리뷰 4건 반영), 버전 정합 6곳
  (pubspec·tool_info·USAGE ×2·SECURITY 0.6.x·cli_test --version), 269 테스트·커버리지 97.04%·
  dead 0·corpus·cli-contract·dry-run 0, 두 SDK CI green → 머지(`85c345a`). GLM 릴리스 리뷰
  (CHANGELOG ×2) 차단 없음·"발행 가능". publish 성공 → 태그 v0.6.0=게시 커밋(`85c345a`, `--target`)
  + GitHub Release → 전파 ~3분 후 pub.dev latest 0.6.0 확인 → 새 격리 캐시 설치본으로 --version
  0.6.0·CLI 계약 59케이스·workspace 멤버십(미목록→`pub-workspace-member-not-listed`+스캔루트 폴백,
  목록→workspace 루트) 검증.
- 로컬 커버리지: 전용 포트 + `format_coverage -i`(플래그 주의). check-analyzer-boundary는
   로컬 rg 부재로 CI 위임.
- 감사 낮음 이월 2건 처분(2026-09-10, PR #69): ① 프로브 4케이스(리터럴 `\x01`·멀티라인
  리터럴·toSource 개행 → 전부 exit 2, 개행 없는 동적 이름 → 정상 방출 대조군) + GRAPH-EXCHANGE
  원문 대조로 현행 유지 판단의 근거를 확정. ② 구현 검증 — format·analyze clean, 269 테스트
  (격리 설치 CLI 계약 포함), 커버리지 97.04%(불변), corpus·cli-contract·dry-run 0, 프로브로
  N=2/N=3 복수형 렌더링 확인, 저장소 전역 grep으로 변경 문자열의 외부 참조 없음 확인.
  GLM packet-review 차단 없음(비차단 — diff 범위는 git diff로 실측 확인; 신규 분기 핀 추가는
  CONTRIBUTING "문구 복제 금지"로 기각; 패킷 밖 소비자는 grep으로 없음 확인; 버전 bump는
  limitations가 검증 제외 자유 문장임으로 기각). 두 SDK CI green 후 머지(`15c4b21`).
- GraphNode isLibrary(PR #71): format·analyze clean, 269 테스트, 커버리지 97.05%, corpus·
  cli-contract·dry-run 0. 실측 대조 — `::` 파일명 + `.dart::` 파일명 + unnamed extension 패키지를
  main(`git archive` 사본) 대비 실행해 실제 그래프 차이가 `.dart::` 파일명 케이스 하나뿐임을
  확인(수정 전 member 오분류·이름 절단 → 수정 후 library). GLM 차단 없음(비차단 — 캐시 히트
  정점 동등성[json 미노출 isLibrary 포함]·생산 플래그·사영 폴백 kind 핀, identity 주석 정리,
  synthesized×isLibrary 문서화, 사영 첫-`::` 접힘 한계 구분 반영; json 재수화 경로 없음·
  unnamed-extension 실그래프 무변경은 실측으로 반박).
- Tier 4 흡수(#72~#75): 각 PR format·analyze clean·전체 테스트·corpus·cli-contract·dry-run 0·
  두 SDK CI green. #72 zone 분류 단위 테스트(고립/주계열/경계==tolerance/pain/uselessness) — GLM
  "차단"(고립 strict 모순)은 패킷 밖 CLI 코드(`!item.isolated && distance > tolerance`)로 해소.
  #73 exporter 직렬화+CLI 종단 테스트, 비순환 무색칠 단언. #74 익명화 단위 테스트(결정성·단사·
  구조 보존·텍스트 치환 범위·삽입 순서 무관) + 실제 analyzer limitation 경로의 CLI 통합 테스트 +
  자기 저장소 도그푸딩(685정점 식별자 누출 0). #75 분류 단위 2종 + CLI 5종(json 정확성·text info·
  SARIF note·조합 usage 64·중복 플래그) + test_only_corpus 확장(기존 소비 무변경 확인). GLM 차단
  3건 — B3(비공개 컨테이너) 수정, B1(멤버 귀속)·B2(의존 스코핑)은 프로브 실측 기각(외부 멤버
  호출의 멤버 정점 정확 귀속·의존 패키지 무정점). 최종 288 테스트·커버리지 97.08%.
- docs(#76): RESEARCH Tier 4 이행 + HANDOFF 세션 전사. 3.11.0 잡이 1회 fail(로그 도메인
  차단으로 원인 미확인) — 재실행으로 통과(같은 코드가 #75에서 양 SDK green이라 플레이크 판정).
- 0.7.0 릴리스(PR #78): 미릴리스 누적 6건(#69, #71~#75)을 semver minor로 발행.
  두 언어 CHANGELOG 0.7.0(완전 동기화), 버전 정합 6곳(pubspec·tool_info·USAGE ×2·SECURITY 0.7.x·
  cli_test --version), format·analyze clean, 288 테스트 통과, 커버리지 97.15%,
  dead 0, corpus·cli-contract(62케이스) 통과, clean git dry-run 0 경고, 두 SDK CI green.
  GLM 릴리스 리뷰: 차단 B1(redundant-public 옵션 결합 계약 정정: --explain/--baseline/--report-test-only
  결합 금지 usage 64, --since 및 머신 리더블 포맷 허용) 및 B2(직렬화 스키마 v3 증가,
  캐시 identity 불변 명시) 반영 후 머지(`e1b3202`). publish 성공 → 태그 v0.7.0=게시 커밋(`e1b3202`)
  + GitHub Release → pub.dev API latest 0.7.0 즉시 확인 → 새 격리 캐시 설치본으로
  --version 0.7.0 및 CLI 계약 62케이스 통과 실측.

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
  멤버십 검증·`unscanned-*` 복수형 문구)도 각각 PR #63·#69로 완료 — 이 이슈의 후속은 전부 소진.
- external-retentions 구현 금지(GRAPH-EXCHANGE 계약, PR #27) 유지.

### 남은 감사 backlog (2026-09-08/09 감사의 미처리분 — 근거는 위 기록과 PR 본문)

- **성능: P1~P6·P8~P10은 #48~#50으로 완료(측정·해시 동일성 포함)**. P7은
  **측정으로 보류 확정(2026-09-09 — 재도출·재측정 금지)**: GraphSnapshot factory의
  이미-Set인 간선 toSet 재해싱. 고립 측정(합성 Set<GraphEdge>·30회 최소) 결과 현실
  규모(600파일 하네스 = 14726 간선)에서 toSet 재해싱은 **24µs** — 인덱싱 min ~1070ms의
  **0.002%**, snapshot 간선 작업의 0.5%에 불과하고 지배 비용은 불변 부분
  `toList()..sort()`(O(E log E)·4506µs, P7이 안 건드림)다. 100k/500k 간선에서도 toSet은
  449/1701µs(≤1%)로 규모 전 구간 negligible. 최적화 후보(`edges is Set ? edges :
  edges.toSet()`)는 동작 동일(Set은 이미 dedup)하지만 24µs(탐지 불가) 이득을 위해 공개
  factory의 방어적 dedup을 뺄 이유가 없다 → **보류**. 전체 A/B+해시는 불필요(프로브가
  P7 비용을 직접 고립 측정했고 동작 동일하므로 7종 해시는 자명하게 같음).
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
- **낮음/기록**: **감사 낮음 실행가능 subset 완료(PR #63)** — html `::` 파일명 오분류(`.dart::`
  판별자 휴리스틱; 잔여 `.dart::` 파일명 + kind threading은 **PR #71 완료로 소진**), SARIF `file:`·`package:`
  uri 손상(원본 source project: 접두 판정 → 절대 URI pass-through; Windows 전용 아님), workspace
  멤버십 검증(목록 일치 + `pub-workspace-member-not-listed` limitation), `_path`의 `project:` 센티널
  충돌은 **vacuous 확인**(항상 prepend→한 번 strip 왕복, 주석 고정). SARIF rules 배열의 testOnly×file
  잠재 불일치(현재 vacuous·주석 고정),
  bridges 동적 이름 toSource 개행 시 전체 문서 실패 — **판단 완료(2026-09-10): 현행 유지로
  종결**(실측·계약 근거는 Completed 이번 세션 절; 완화는 isthmus 조율 없이 금지, 재론 금지),
  bridge limitations 미정렬(생산자 고정 순서라 결정성
  유지), graph_exporter limitations 미dedup(CLI가 선행 dedup), **bridge_index 스코프 방문자
  — 완료(PR #61, 감사 T4: catch/for/지역함수/클로저/채널 재대입 + 섀도잉 단언, 미커버
  40→9줄)**, 남은 9줄은 vacuous/비실용(165-168 비교자 동일-offset tiebreaker·217 TOCTOU
  race·718 resolved flutter 필요·833-835 조건부 re-export — 재추격 금지),
  cli 잔여 57줄(희귀 분기), `<no-library>` 파일 수준 합류(의도·문서화됨). 감사 T6
  (graph_projection:43·cycle_detector 방어 분기)은 도달불가/무해 확인 — 재도출 금지.
- **`unscanned-*` 복수형 문구 — 완료(PR #69, 2026-09-10)**: 3개 family 일괄 정리(unscanned-*
  N≥2 복수형 + dynamic-* N=1 단수 문법[실측 발견]). 나머지 family 형식과 동일한 삼항식,
  N≥2 dynamic-*·N=1 unscanned-* 바이트 불변, 접두사 불변(GRAPH-EXCHANGE: limitations은
  소비자가 검증하지 않는 자유 문장). 상세·검증은 Completed 이번 세션 절. **미릴리스.**
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
  이번 세션(#74)에도 anon 작업을 main에 커밋했다 — 원격 main 보호가 직접 push를 거부해줘
  사고가 새어나가지 않았고 같은 절차로 복구했다. 원격 거부는 마지막 안전망이지 허가가
  아니다: 커밋 전 `git branch --show-current`를 습관화한다.
- **gh release create의 positional sha는 에셋 glob**으로 해석된다 — `--target <sha>` 사용.
- **python 치환은 dart format 후에 앵커가 어긋난다** — 편집 전 현재 본문을 읽고, 포맷된
  텍스트에 대해 edit 도구를 쓴다(heredoc+python은 따옴표·백틱 충돌이 잦다).
- **한국어 산문에 한자·일본어 혼입 반복**(이번 세션 6회+) — 커밋·문서 작성 후 CJK 스캔
  (`[\u3040-\u30ff\u4e00-\u9fff]`)을 습관화한다. push 전이면 amend, 후면 후속 커밋.
- **미커밋 작업의 브랜치 확인**: D·E 작업을 선행 PR 브랜치 위에서 시작해 stash 이동을
  2번 반복했다. 새 작업 시작 전 `git branch --show-current`.
- **dry-run은 clean git에서만 경고 0** — 미커밋 변경 자체가 경고다.
- packet-review는 시간당 6회 — 다중 PR 세션은 페이싱하고, 리뷰어 권장의 기계적 구현
  delta는 재전송을 생략할 수 있다(사유 기록). 이 세션 운영 노트: 래퍼는 --files가 사실상
  필수(빼면 unbound variable로 실패)고 --diff와 병용 불가 — 변경 파일을 --files로 주고
  질문에 브랜치 범위를 서술하는 방식이 동작한다. 응답이 길면 tail 절단으로 서두(차단
  항목 본문)가 사라질 수 있으니 결론 문단이 잘리면 처음부터 다시 읽는다.
- `gh pr create` 본문을 `"$(cat <<'EOF' …)"` 치환으로 넘길 때 내용에 백틱·괄호 조합에 따라
  bad substitution이 난다(이번 세션 1회) — 본문을 `$TMPDIR` 파일로 쓰고 `--body-file`로
  넘기면 재현 없이 해결된다.
- CI 잡 로그는 results-receiver 도메인(차단)이라 `gh run view --log`·API zip 모두 막힌다 —
  잡의 실패 스텝은 `gh api .../jobs/<id> --jq '.steps[]'`로 확인하고, docs 전용 PR의 단일
  SDK fail은 같은 코드가 직전 제품 PR에서 green이면 `gh run rerun --failed`로 플레이크를
  가른다(#76에서 실증).
- 샌드박스: rg 없음(bash grep, boundary 게이트는 CI), Write 도구는 워크스페이스 밖 거부
  (PR 본문은 bash heredoc), 커버리지는 전용 포트, macOS는 비-UTF8 파일명·`::` 파일명
  생성 가능(개행 파일명도 가능 — 주입 테스트에 활용).
- **반쪽 수정 금지 / 게이트별 exit code 개별 확인 / Directory.current 프로세스 전역 /
  상대 경로 파일 쓰기 오염 주의 / 실패 재현은 올바른 기준 커밋에서 / main 직접 커밋
  금지 / 기본값 출력 보존은 회귀로 고정** — 계속 유효.

## Next Steps

1. 실제 branch/status/log를 확인하고 루트 및 작업 경로 AGENTS.md를 읽는다.
2. 지금까지 완료: PR #39~#54(0.4.1·0.5.0 릴리스 + 성능 backlog + issue #38 dartograph 측)
   + PR #57~#68(issue #38 종결 + 죽은 API 처분 + README 퇴고 + 0.6.0 릴리스)
   + PR #69~#76(감사 낮음 처분 2건 + GraphNode isLibrary + Tier 4 4종 흡수)
   + **PR #78(0.7.0 릴리스 완료 — 미릴리스 누적 6건 전량 발행)**.
   완료된 구현·감사·측정·릴리스·처분을 반복하지 않는다. **미릴리스 누적 0건**.
3. **다음 세션 이월분**:
   - 남은 흡수 범위 = RESEARCH **Tier 3**(yaml 확장·init·markdown/codeowners 리포터·issue-type 필터·MCP 서버) — 사용자 요청 시 PRD/PLAN에서 범위 결정.
4. 제품 배포 blocker 없음. 다음 명시적인 사용자 지시를 따른다.

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/dartograph`, read `HANDOFF.md` and applicable `AGENTS.md` files, then continue from: `Verify current Git state. Product 0.7.0 is released (pub.dev latest 0.7.0 with ENGLISH README/Changelog, tag v0.7.0 at e1b3202 = publish commit, GitHub Release, fresh-cache install verified incl. --version 0.7.0 and the 62-case CLI contract; previous releases: 0.6.0 at 85c345a, 0.5.0 at 16b18fd, 0.4.1 at 53a4e0f). PR #78 bundled all six unreleased items (#69 bridges limitation grammar, #71 GraphNode isLibrary with cache schema v3, #72 metrics architectural zone labels, #73 DOT cycle node coloring, #74 graph --format anon, #75 dead --report-redundant-public) as a semver minor release with full twin CHANGELOG synchronization. GLM release review feedback was addressed (redundant-public option combination contract clarified, cache schema v3 vs cache identity disambiguated). NOTHING is unreleased (0 unreleased PRs). Line coverage is 97.15% across 288 tests. Next steps: Tier 3 absorption candidates in doc/RESEARCH.md (yaml extensions, init, markdown/codeowners reporters, issue-type filter, MCP server) to be decided on user request. Follow the next explicit user task.`

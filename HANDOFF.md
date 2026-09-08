# Handoff

_Last updated: 2026-09-08 (0.3.0 릴리스 + 감사 backlog 7건 정리, PR #19 merge 기준)_

## Goal

- 영구 무료 MIT Dart/Flutter 근거 질의 CLI를 유지한다.
- 이번 세션은 이전 9축 감사가 남긴 backlog의 상위 4건을 재현→수정→회귀→GLM 리뷰로
  반영하고(PR #18), 0.2.0 이후 누적된 미릴리스 변경 전체를 0.3.0으로 공개한 뒤(PR #19,
  pub.dev·GitHub Release), 남은 backlog 7건(릴리스 전 처리 목록)도 정리했다
  (`fix/pre-release-backlog`). 새 대형 기능 요청은 없었다.

## Current Status

- 릴리스 기준: `v0.3.0` → `92826d0` (PR #19 merge). pub.dev(latest 0.3.0)·GitHub Release
  공개 완료. 새 격리 캐시 설치로 `dartograph 0.3.0`을 확인했다.
- main 기준: `92826d0` (PR #19 merge). 0.2.0 이후 누적됐던 `entry_points`(#9)·analyzer 계약
  테스트(#10)·lakos(#11)·결함 수정(#13~#17)·감사 backlog 상위 4건은 모두 0.3.0에 릴리스됐다.
  이후 감사 backlog의 남은 7건(릴리스 전 처리 목록)을 브랜치 `fix/pre-release-backlog`에서
  정리했으며 이는 **미릴리스**(다음 0.3.x/0.4.0 후보)다.
- 지침 기준: `c4d121d` (PR #7 merge).
- 이번 세션은 backlog 상위 4건을 PR #18로, 0.3.0 릴리스를 PR #19로 머지·게시했다.
  열린 제품 PR은 없다.
- 정본은 루트 AGENTS.md이며 CLAUDE.md는 이를 참조한다. 하위 규칙은 lib, lib/src/index,
  test, fixtures, tool, doc에 있다. 적용 범위는 링크가 아니라 디렉터리 위치로 결정된다.
- 제품 배포 blocker는 없다. HANDOFF 내용이 Git 상태보다 우선하지 않으므로 재개 시 실제 상태를 확인한다.

## Completed

### 이번 세션 (감사 backlog 상위 4건 + 0.3.0 릴리스, PR #18·#19 머지)

- **bridge 채널 선언 순서(#1)**: 클래스 등 선언 본문에서 `static final _c = MethodChannel(...)`이
  사용처보다 뒤에 선언되면 analyzer가 소스 순서로 방문하므로 사용처에서 `_c`를 해결하지
  못해 method-invoke fact가 통째로 누락되고 `unresolved-receiver-invocations`로 강등됐다.
  `_visitDeclarationScope`에 본문 선-스캔 콜백(`_prescanFields`)을 추가해 class/mixin/enum/
  extension/extensionType의 멤버 필드를 먼저 등록한다. 선-스캔은 2패스(상수 등록→채널 해석)라
  클래스 필드 사이에서도 `MethodChannel(_name)`이 `const _name`보다 앞에 와도 정적으로 해석한다.
  **analyzer 14.3.0은 멤버가 `node.body.members`(ClassBody/EnumBody)로 옮겨갔다**(`node.members`
  아님). 동명 최상위 채널 shadowing도 순서와 무관하게 유지된다.
- **`.values` enum 상수 오탐(#2)**: enum 상수는 `FieldElement`(isEnumConstant)라 노드로 만들어지고
  enum→상수 간선은 `member`(impliesUsage=false)뿐이다. 컨테이너 구제는 멤버→컨테이너 단방향이라
  `Status.values`로만 소비되는 도달 가능 enum의 상수까지 `dead`로 잘못 보고됐다(실행 재현: 상수 3건).
  GraphNode에 `isEnumConstant`를 추가하고 도달성이 "enum이 도달 가능하면 상수도 보존"으로 구제한다.
  `explain`은 `retained by its reachable enum` 근거와 enum까지의 경로를 낸다(symbol_query는
  `explanation.reachable`로 자동 반영, graph_comparison는 `deadDeclarations`로 자동 반영).
  enum 자체가 미도달이면 상수도 계속 보고한다(과보존 방지 회귀 포함).
- **빈 채널명 전면 실패(#3)**: `_rejectControlCharacters`가 빈 값에도 던져 `MethodChannel('')`
  한 줄이 `bridges` 출력 전체를 실패시켰다. 이제 `_fact`가 빈 채널·메서드 이름이면 그 fact만
  건너뛰고 `empty-bridge-names: N` limitation으로 집계한다. 제어 문자는 계속 전면 거부한다
  (기존 `bridges rejects Unicode line controls` 테스트 유지).
- **`dead --since`의 `diff.relative`(#4)**: `git diff`가 cwd 상대 경로를 출력하는데 저장소 루트와
  join해, 패키지 루트≠저장소 루트 + `diff.relative=true`에서 변경 파일 집합이 어긋나 발견이
  전부 사라졌다(종료 0). `_run`이 git을 `-c diff.relative=false`로 실행해 경로를 고정한다.
- **0.3.0 릴리스(PR #19)**: 위 4건(PR #18)과 0.2.0 이후 누적된 미릴리스 변경 전체를 0.3.0으로
  공개했다. pubspec·toolVersion을 0.3.0으로 맞추고 CHANGELOG의 `Unreleased`를 `0.3.0`으로 옮겼다.
  릴리스 전 처리 목록의 SKILL.md 문구(`entry_points` 반영)와 SECURITY.md(지원 0.3.x)를 정리하고
  `isNot(contains('entry_points'))` 유물 단언을 제거·반전했다. pub.dev 게시·태그 v0.3.0·GitHub
  Release·새 캐시 설치 확인까지 완료했다.

### 이전 세션 (#13~#17, 0.3.0에 릴리스)

- **심볼릭 링크 캐시 오염(PR #13, blocker)**: `listSync(followLinks: false)` 목록에서 링크는
  `Link` 인스턴스라 `File`·`Directory` 분기에 걸리지 않아 캐시 키 입력에서 빠졌다. analyzer는
  파일·디렉터리 링크를 모두 따라가 분석하므로, 링크 대상을 수정해도 키가 그대로여서 낡은
  그래프를 영구 반환했다. `fact_cache.dart`의 "캐시가 꺼졌을 때 사실이 달라지지 않아야 한다"
  계약 위반이다. 두 순회 함수(`_projectFiles`, `_dartFiles`)가 링크를 따라가되, 이미 따라간
  대상의 실제 경로를 기록해 순환에서 무한 순회하지 않는다. 재귀는 링크 경로로 수행해 해싱되는
  상대 경로가 analyzer가 쓰는 경로와 같은 모양을 유지한다. 링크된 소스의 bridge fact 누락도
  같이 해소됐다. 캐시 revision은 올리지 않았다(근거는 아래 Facts).
- **explain 멤버 보존(PR #14)**: `explain`이 `_paths`에 없으면 즉시 미도달로 답해, 같은 실행의
  `dead`가 발견에서 제외한 컨테이너를 "unreachable"로 단정하고 종료 코드 1을 냈다. 이제
  witness 멤버를 찾아 `retained by a reachable member` 근거와 그 멤버까지의 실제 경로·간선을
  돌려준다. `explain`이 정직해지면 `reachable`만 보던 `symbol_query`·`graph_comparison`이
  witness를 잃으므로, 두 곳의 판별자를 직접 도달(`reachableIds.contains`)로 바꿔 기존 출력을
  유지했다.
- **빈 dartograph.yaml(PR #15)**: `loadYaml` 결과가 `YamlMap`이 아니면 던지는 분기에 빈 문서가
  걸려 `touch dartograph.yaml` 한 번으로 모든 명령이 종료 코드 2로 죽었다. doc comment와
  `lib/src/index/AGENTS.md`가 규정한 "파일이나 키가 없으면 기본 보수 정책"과 어긋난다.
  null로 해석되는 문서는 기본 정책으로 되돌리고 비어 있지 않은 비-mapping만 거부한다.
- **옵션 모양 경로(PR #16)**: `baseline --write --force .`이 `--force`라는 이름의 파일을 실제로
  만들고 종료 코드 0을 냈다. 값이 빠진 호출이 usage(64)가 아니라 분석 실패(2)로 보고되는
  같은 계열 결함이 `query`·`bridges`·`graph`의 루트, `rules --config`, `dead --baseline`·
  `--since`, `compare`(단일 대시)에 있었다. `query --batch`가 이미 쓰던 `startsWith('-')`
  기준을 CLI 전체로 확장했다. **좁은 파괴적 변경**이며 우회법은 `./-name`(bridges는 `--`)이다.
- **산출물 제거(PR #17)**: 위 재발 검증 과정에서 `--force` 파일이 저장소에 커밋됐던 것을 지우고,
  baseline 목적지가 옵션 모양인 테스트 케이스를 cwd 통제 테스트로 옮겼다.

### 이전 세션에서 유지되는 것

- `dartograph.yaml`의 `entry_points`(0.3.0에 릴리스): 선언된 build target 파일의 `main`만 보존 루트로 좁힌다.
  없으면 기본 보수 정책. 잘못된 설정은 FormatException(종료 2), `main` 없는 진입점은 limitation.
- analyzer 호환 범위 계약 테스트(PR #10): 런타임 실제 버전이 `doc/DECISION-analyzer.md`의
  검증 범위(14.3.x) 안인지 강제한다. 버전 트레드밀 가드.
- lakos 리서치 정리(PR #11): `doc/RESEARCH.md`에서 "확인됨"으로 옮기고 `doc/PRD.md` 비교표에 반영.
- `query --batch`, `compare`, 소스별 한계 연결, bridge qualifiedName, 변형 회귀·벤치마크 도구.
- 0.1.1의 provenance·scope·UTF-8 위치·UTC 밀리초·중첩 캐시·protobuf·CLI 오류 보강.

## Key Files & State

- `lib/src/core/graph_node.dart`: `isEnumConstant` 플래그가 enum 상수 노드를 표시한다
  (`isTypeDeclaration`과 상호배제 검증). 도달성 보존의 근거다.
- `lib/src/analysis/reachability_analyzer.dart`: dead/explain, known·witness, 소스별 한계.
  `_reachableMemberOf`가 멤버 보존 witness를 고른다. `reachableEnumConstants`가 도달 가능
  enum의 상수를 보존하고 explain은 `retained by its reachable enum`을 낸다.
- `lib/src/analysis/symbol_query.dart`, `lib/src/analysis/graph_comparison.dart`:
  판별자가 `reachableIds.contains`(직접 도달)다. enum 상수 보존은 `explanation.reachable`·
  `deadDeclarations`로 자동 반영된다. 직접 도달 판별자를 `explanation.reachable`로 되돌리면 회귀한다.
- `lib/src/index/analyzer_graph_index.dart`: analyzer 어댑터·소스 진단·중첩 의존성 캐시.
  `visitDeclaration`가 `isEnumConstant: element is FieldElement && element.isEnumConstant`를
  설정해 캐시 직렬화에 포함한다. `_cacheSchemaVersion = 2`(옛 캐시는 decode 거부·재분석).
  **analyzer 14.3.0은 클래스 멤버가 `node.body.members`(ClassBody/EnumBody)다**(`node.members` 아님).
- `lib/src/index/bridge_index.dart`: Flutter provenance·scope·Dart 선언 이름·bridge facts.
  `_visitDeclarationScope`가 `_prescanFields(node.body.members...)`로 선언 본문 필드를 선-스캔한다.
  `_fact`는 빈 채널·메서드 이름이면 null을 돌려주고 `emptyBridgeNames`로 집계한다(제어 문자는 계속 거부).
- `lib/src/cli/changed_files.dart`: `_run`이 git을 `-c diff.relative=false`로 실행해 경로를 고정한다.
- `lib/src/cli/dartograph_cli.dart`: 입력 검증·batch/compare·0/1/2/64 계약.
  모든 위치 경로와 파일 값이 `startsWith('-')`로 걸러진다(`--explain` 값은 의도적 제외).
- `fixtures/false_positive_corpus/lib/enums.dart`·`main.dart`: `.values`로만 소비되는
  `TelemetryLevel`로 enum 상수 보존을 검증한다. `tool/verify-false-positive-corpus.sh`의
  preserved 목록에 `TelemetryLevel`이 있다.
- `test/analysis/reachability_analyzer_test.dart`: enum 상수 보존(`.values`)과 과보존 방지
  (미도달 enum은 상수도 보고) 회귀.
- `test/index/bridge_symbol_test.dart`: 채널 선언 순서·shadowing·빈 채널명 회귀.
- `test/cli/changed_files_test.dart`: `diff.relative=true` + nested 패키지 회귀.
- `test/index/fact_cache_test.dart`: 파일 링크·디렉터리 링크 캐시 무효화와 순환 가드 회귀.
- `test/cli/dartograph_cli_test.dart`: 옵션 모양 값 거부 회귀. baseline 목적지 케이스는
  cwd 통제 테스트에만 둔다(상대 경로가 저장소 루트에 쓰이는 것을 막기 위해).
- `test/index/analyzer_graph_index_test.dart`: entry_points 축소·한계·거부·빈 문서·BOM 회귀.
- `test/analysis/evidence_workflow_test.dart`: query `retainedByMember`·compare witness 회귀.
- `.github/workflows/ci.yml`: Dart 3.11.0/3.13.3 matrix.
- `doc/USAGE.md`: 실제 명령·한계·enum 보존. `CHANGELOG.md`: 0.3.0(이번 릴리스)과 0.2.0 이하 내역.

## Important Context / Decisions

- Facts:
  - cache identity는 `dartograph-analysis-$toolVersion-cache-v3-entry-points`다.
    추출 의미 변경 시 revision을 갱신한다. `dartograph.yaml`도 캐시 키에 포함한다.
    enum 상수 보존(#2)은 노드 직렬화에 `isEnumConstant`를 추가해 `_cacheSchemaVersion`을 2로
    올렸다(옛 캐시는 decode에서 schemaVersion 불일치로 거부·재분석). identity는 그대로다
    (도달성은 캐시 밖이고 노드 집합도 변하지 않았다).
  - enum 상수는 `FieldElement`(isEnumConstant)라 노드로 만들어지고 enum→상수는 `member` 간선뿐이다.
    `.values`·switch·직렬화는 개별 상수를 직접 참조하지 않으므로, enum이 도달 가능하면 상수도
    보존한다(과보존 방지: enum 자체가 미도달이면 상수도 보고). extension type은 이번 세션에서
    재현하지 않아 같은 공백이 있는지 미확인이다.
  - analyzer 14.3.0은 클래스/믹스인/enum/extension/extensionType 멤버가 `node.body.members`
    (ClassBody·EnumBody의 `NodeList<ClassMember>`)다. 구버전의 `node.members`가 아니다.
  - 심볼릭 링크 수정은 revision을 올리지 않았다. 추출 의미가 그대로이고, 링크 없는 프로젝트는
    동일한 입력 목록을 해싱해 기존 캐시가 유효하며, 링크 있는 프로젝트는 애초에 잘못된 사실을
    캐싱했고 새 키가 그것을 자연히 비껴간다.
  - 링크 대상의 실제 경로가 아니라 **링크 경로**로 해싱한다. 링크 추가·제거·이름 변경은 어떤
    파일 내용도 바꾸지 않지만 그래프 노드 경로 집합을 바꾸므로, resolved-path로 dedup하면
    링크 제거 방향의 stale이 새로 생긴다.
  - `explain`의 witness 경로는 witness 멤버에서 끝난다(`path.last == witness`). 존재하지 않는
    멤버→컨테이너 간선을 지어내지 않는다.
  - `yaml-3.1.x`는 빈 문서·개행만·주석뿐·`---`만·공백/탭만·BOM만·`null`·`~`를 모두 null로
    돌려준다. `{}`는 YamlMap, `[]`는 YamlList, 다중 문서·중복 키·malformed는 `YamlException`
    (=`FormatException`)이라 종료 코드 2 계약을 지킨다. BOM은 제거되므로 키를 가리지 않는다.
  - 소스 한계는 파일 수준 관측이다. 한계 없음은 안전성 보증이 아니다.
  - compare는 인과 증명이나 삭제 판정이 아니다. rename은 삭제/추가로 보인다.
  - bridge의 qualifiedName은 어휘적 이름이다. Dart 컴파일러 USR을 발명하지 않는다.
  - isthmus가 언어 간 조인을 소유한다. 직접 Flutter services import만 provenance로 인정한다.
- Assumptions:
  - isthmus 왕복은 로컬에 준비된 소비자를 사용했다. 새 환경에서 설치 경로·버전을 확인해야 한다.
  - HANDOFF의 검증 수치는 아래 명시한 작업의 기록이며 이후 변경까지 보증하지 않는다.

## Verification

- 이번 세션 검증(0.3.0 릴리스, PR #18·#19): SDK는 homebrew `dart 3.13.3`, 의존성은 `dart pub get`
  (**온라인**)으로 격리 PUB_CACHE에 받아 `package_config.json`이 격리 경로를 가리킨다(`--offline`은
  빈 캐시에서 exit 69). `dart format`·`dart analyze` clean(각각 exit 0), **전체 139개 테스트 통과**
  (exit 0), 오탐 코퍼스·CLI 계약 스크립트 exit 0. PR #18·#19 각각 두 SDK(3.11.0/3.13.3) CI green
  후 머지했고 CI의 `check-coverage.sh`가 커버리지 게이트(≥90)를 검증했다.
- **0.3.0 릴리스 검증**: clean git에서 `dart pub publish --dry-run` 경고 0(70 KB). pub.dev 게시
  성공(latest 0.3.0 전파 확인), 태그 v0.3.0(annotated "dartograph 0.3.0")·GitHub Release 공개,
  새 격리 캐시에 `dart pub global activate dartograph 0.3.0` 후 설치 바이너리가 `dartograph 0.3.0`을
  출력(exit 0). 게시는 자격 증명을 `~/.config/dart/`에서 macOS pub이 읽는
  `~/Library/Application Support/dart/pub-credentials.json`로 복사한 뒤 토큰 인증으로 성공했다
  (OAuth 로컬 포트 바인딩은 sandbox EPERM).
- GLM 리뷰는 agent-guard `packet-review`(샌드박스 내 유일한 GLM 경로, `--files` 단독)로 받았다.
  본 리뷰·delta 리뷰 모두 **차단 이슈 없음(승인)**. 본 리뷰의 최우선 지적(rescued enum 상수가
  `reachableIds`에 없어 query/compare가 갈릴 수 있다)은 실측으로 기각했다: `query`는 상수를
  `state: reachable`(path=enum까지)로 답하고, `compare`는 `deadDeclarations` 기반이라 rescue가
  자동 반영된다. 권고 #2(`_prescanFields` 2패스)·#3(비클래스 본문 prescan 커버리지)와 delta의
  non-blocking 2건(shadow-const, 비클래스 2패스)을 반영해 bridge_symbol_test가 7건으로 늘었다.
- **로컬 라인 커버리지는 sandbox에서 미실행**: `dart test --coverage`의 VM service(로컬 포트)가
  차단되어 가벼운 테스트 한 개로도 hang한다(커버리지 없는 `dart test`는 ~28초 통과). 대신 PR CI의
  `check-coverage.sh`가 두 SDK에서 ≥90 게이트를 통과시켰다.
- 각 수정은 **수정 전 실패를 재현한 뒤** 통과시켰다. 이번 세션 재현 근거: bridge 채널 순서·
  shadowing·빈 채널명 3건과 `diff.relative` nested 1건은 제품 코드만 `git stash`했을 때 실패,
  enum 오탐은 `Status.values`만 소비하는 패키지에서 `dead --format json`이 상수 3건을 보고
  (수정 후 `findings: []`), reachability 보존 테스트는 `reachability_analyzer.dart`만 stash했을 때 실패.
- 아래는 이전 세션(#13~#17) 시점의 기록이다.
- 현재 main(`86ee109`) 로컬 검증: `dart format`·`dart analyze` clean(각각 exit 0),
  **전체 129개 테스트 통과**, 라인 커버리지 **93.12%**(2193/2355, ≥90 게이트).
  오탐 코퍼스·CLI 계약 스크립트 exit 0. `dart pub publish --dry-run` exit 0, 경고 0.
- PR #13~#16 각각 Dart 3.11.0/3.13.3 CI green 후 머지. #13·#14·#15·#16은 GLM 리뷰를 받았고
  모두 최종 blocker 없음이었다. #17은 사용자 지시로 리뷰를 생략했다.
- 각 수정은 **수정 전 실패를 재현한 뒤** 통과시켰다. CLI 레벨 재현 근거:
  캐시 on/off 결과 불일치(0건 vs 1건, 2건 vs 3건), `explain` 종료 코드 1→0,
  `touch dartograph.yaml` 후 exit 2→0, `baseline --write --force .` exit 0+파일 생성 → 64+미생성.
- 0.2.0 기능 검증: format·analyze 통과, 전체 116개 테스트, 라인 커버리지 92.47%.
- 0.2.0 dry-run: 58 KB, 경고 0. 공개 pub.dev 패키지의 새 격리 설치와 전체 CLI 계약 통과.
- `dart run tool/benchmark_query.dart`: 합성 2,000노드/100질의, 약 227ms → 8ms.
  실제 프로젝트 SLA나 독립 성능 평가가 아니다.
- `dart run tool/verify_bridge_query.dart <isthmus-main.js>`: 합성 Swift fact 왕복.
  Swift 컴파일러/실제 앱 검증을 대체하지 않는다.

## Blockers & Open Questions

- 필수 제품 작업 없음. 열린 제품 PR 없음.
- 아래 세 목록은 다르다. **감사 backlog**는 근거가 확인된 미처리 항목,
  **닫은 항목**은 다시 도출하지 말 것, **보류 항목**은 요구·측정·외부 조율이 생기면 재검토한다.

### 감사 backlog (이전 9축 감사에서 이중 검증 통과, 미처리)

우선순위 상위 4건(bridge 채널 선언 순서, `.values` enum 상수 오탐, 빈 채널명, `dead --since`의
`diff.relative`)은 이번 세션에서 처리해 Completed로 옮겼다. 아래는 남은 항목이다.

릴리스 전 처리 목록은 **모두 처리했다**. SKILL.md 문구·SECURITY.md 지원 버전은 0.3.0 릴리스(PR #19)에서,
나머지 7건은 백로그 정리 브랜치(`fix/pre-release-backlog`)에서 재현→수정→회귀로 반영했다:

- CONTRIBUTING 릴리스 정합성 목록에 SECURITY.md 등재
- `verify-cli-contract.sh`에 `graph`(dot·mermaid·실패)·`skill`·`bridges`(성공·실패)·`baseline --write` 게이트 추가
- `_readBaseline`이 baseline 부재(FileSystemException)도 invalid로, `_runRules`가 config 부재·오류를
  `Analysis failed: unable to read the rules configuration.`으로 구분(기존 `Analysis failed:` 접두·path 미노출 계약 유지)
- `_librarySource`가 `Uri.path`의 퍼센트 인코딩을 `Uri.decodeComponent`로 디코딩해 파일 수준 한계가 매치됨
  (파급은 dead **file** finding의 source뿐. layer_rules·graph_exporter·symbol_query는 `node.sourceUri`/`node.id`를 직접 써 무관)
- Mermaid 전용 `_escapeMermaid`(`&`·`<`·`>` 엔티티)로 자체 노드 ID 인코딩
- `analysis_options.yaml`의 `public_member_api_docs: error` 승격(CI `dart analyze`가 info를 실패로 잡음)
- USAGE의 layers.yaml 스키마 예시 + `--help`의 `--explain` json 강제·no-baseline·no-since 안내

GLM 리뷰가 남긴 후속 후보(이번 범위 밖, 낮음):

- `_runBaseline`의 `BaselineStore.write` FileSystemException(쓰기 불가 경로)이 `on Exception`으로
  "unable to index the package."로 답해, C가 고친 것과 같은 원인 오인이 baseline 쓰기 경로에 잔여한다.
- `_escapeMermaid`가 `"`·`\`를 처리하지 않는다. 따옴표 포함 파일명은 Mermaid 라벨 구조를 깰 수 있어
  `#quot;`(Mermaid 문법) 추가가 후속 후보다(각도 괄호가 합성 ID로 흔해 이번엔 `&`·`<`·`>`만 처리했다).

아래는 **선택 과제**와 확인 후보다.

선택 과제:

- `lib/src/core/code_graph.dart`의 `nodes` 게터(:13)가 호출마다 전체 정점 맵을 복사·정렬하는데
  `_addPublicApiRoots`(`analyzer_graph_index.dart:873`)가 export 루프 안에서 호출한다.
  루프 진입 전 hoist. **수치 근거 없음**(감사의 수치는 가정 시나리오였다). 배럴을 가진
  라이브러리 패키지만 해당한다.
- `test/analysis/architecture_metrics_test.dart:47` — 정렬 규칙이 어떤 테스트에서도 구별되지
  않아 비교자를 뒤집거나 지워도 전부 통과한다. 문서화된 사용자 계약 위반은 아니다.
- 테스트 9곳이 `FactCache`를 주입하지 않아 실행마다 사용자 홈 캐시에 디렉터리를 남긴다
  (`fact_cache_test.dart`가 이미 정상 패턴을 보여준다). **개발자 머신 한정**이다.
- `lib/dartograph.dart`가 `SymbolQuerySession.analysis`의 타입 `ReachabilityResult`를 내보내지
  않아 게시된 API만 쓰는 소비자가 그 값을 타입으로 선언할 수 없다. 지원 API로 유지할지 먼저 결정.
- `metrics --strict`의 임계값 `tolerance = 0.3`이 도움말·문서 어디에도 없다. 판정에 쓰이는
  `distance`·`isolated`·`tolerance`는 이미 출력에 있으므로 산문 한 줄이면 된다.
- analyzer 패키지 버전이 캐시 키에 없다. `dart pub global activate`로 쓸 때만 해당하고
  노후화 창은 "같은 dartograph 버전 + 14.3.x patch 차이"로 한정된다.
- `dartograph_cli.dart`의 `query --baseline`(`suppressedIds`, :391)이 baseline의 dead **file** 항목을 억제 대상으로
  계산하지 않아 같은 baseline에 대해 명령 간 finding 집합이 어긋난다.
- `doc/PRD.md:103`이 "README 용"이라 지정한 경쟁 비교표가 README에 없다. lakos가 README에
  한 번도 등장하지 않는다.

### 검토 후 닫은 항목 (간과가 아님)

- bridges limitation "보강" — limitation은 이미 포괄·정확해 안전한 실질 개선이 없다. 복수형
  문구 정정은 `AGENTS.md`의 문구-변경 비권장에, location 추가는 카운트+전역경고 설계 철학에
  각각 충돌한다. 유일한 실질 개선(EventChannel·BasicMessageChannel fact화)은 보류 항목을 본다.
- 대형 모듈 분리(`analyzer_graph_index`·`bridge_index`·`dartograph_cli`) — 세 파일은 코헤시브하고
  잘 테스트된다. 크기 주도 분리는 최소-diff·"요청받지 않은 리팩토링 금지" 원칙과 충돌한다.
- HANDOFF의 기준 커밋 표류·커버리지 로컬-CI 차이·`.dart_tool` 정리 기록 — 이번 감사에서 도출됐으나
  전부 기각됐다. 문서가 자기 머지 커밋을 미리 적는 것은 원리적으로 불가능하고, 커버리지는
  "로컬 검증"이라 이미 명시돼 있으며 게이트는 절대 하한이고, gitignore 대상 산출물은 어떤
  문구로 고쳐도 즉시 낡는다.
- `.pubignore`가 `.gitignore`를 대체해 로컬 상태 디렉터리가 pub 아카이브에 유출된다는 주장 —
  pub은 ignore 파일과 무관하게 점(.) 접두 최상위 항목을 무조건 제외한다(실험 확인).
- PRD 성공 기준(공개 Flutter 3개 손 검증) 기록 없음 / `compare`·`query --batch`가 PRD·PLAN에
  없음 — 각각 `self_analysis_test.dart`와 corpus가 CI 기준선으로 존재하고, PRD의 의무는
  *미구현* 표기이며 릴리스 대장은 CHANGELOG가 담당한다.

### 검토 후 보류한 항목 (간과가 아님)

- `package:args` 전환 — 전면 교체는 CLI 계약과 다수 테스트 재작성을 요구하지만 이득이 미미하다.
- isolate 병렬화로 cold-run 30초 SLA 달성 — 30초 검증에 대형 실제 Flutter 체크아웃이 필요하며
  측정 없는 최적화는 금지된다.
- melos 멀티패키지 — 대형 신규 기능. `doc/PRD.md`의 v0.2+ 범위로 유지한다.
- EventChannel·BasicMessageChannel fact화 — isthmus와 GRAPH-EXCHANGE 시맨틱 조율 없이 fact
  kind를 바꾸지 않는다. 현재는 limitation으로만 센다.
- 무료·JSON·MCP만으로 해자가 입증되지는 않았다. 사용자 피드백 유입·회귀 대응·외부 계약 채택은
  검증할 전략 가설이다.

## What Worked / Avoid

- **반쪽 수정을 남기지 않는다.** #13에서 GLM이 "analyzer가 디렉터리 링크를 따라간다면 같은 결함이
  남는다"고 조건부로 지적했고, 실측하니 조건이 성립했다. 파일 링크만 고치고 넘어갔다면 고치려던
  계약을 그대로 위반했을 것이다. #16도 지목된 3곳만 고친 뒤 전수 확인해 4곳을 더 찾았다.
- **GLM 지적은 실제 코드·측정으로 검증한다.** 이번 세션에서 기각한 것: `reachableIds` 미정렬
  주장(`reachability_analyzer.dart:405`의 `paths.keys.toList()..sort()`가 반증), `graph_comparison`의 `direct` 미사용 주장,
  `--explain` 오타가 분석 실패(2)를 낸다는 주장(실측 64), 심볼 ID가 대시로 시작할 수 있다는 주장.
  반대로 TOCTOU 크래시 경로, 호환성 서술 오류, CLI 회귀 부재는 실제 결함이라 반영했다.
- **게이트 명령은 각각의 exit code를 따로 확인한다.** `cmd1; cmd2; cmd3 | tail`처럼 이으면
  마지막 명령의 코드만 남아 `dart format` 실패가 가려진다. 실제로 CI를 한 번 깨뜨렸다.
- **`Directory.current`는 프로세스 전역이다.** `dart test`가 스위트를 병렬 실행하므로 인덱싱
  동안 cwd를 붙잡으면 다른 스위트가 상대 경로를 잃고 exit 255로 죽는다. cwd 접촉면을 최소화한다.
- **테스트가 상대 경로로 파일을 쓸 수 있으면 저장소를 오염시킨다.** 수정을 되돌려 실패를 재현할 때
  `baseline --write --force <root>`가 저장소 루트에 파일을 만들었고 `git add -A`가 쓸어담아
  main까지 갔다(PR #17로 제거). 쓰기가 걸린 음성 케이스는 cwd를 통제하는 테스트에만 둔다.
- **수정 전 실패 재현은 올바른 기준 커밋으로 한다.** `git checkout main -- <file>`은 그 수정이
  이미 머지된 뒤에는 무의미하다. 한 번 무효한 검증을 했다가 재실행했다.
- `dart pub get` 전에 `dart analyze`를 돌리면 의존성 미해석으로 가짜 error가 대량으로 뜬다.
- 대상 fixture 소스를 런타임으로 실행하지 않고 analyzer로 변형 결과를 검사했다.
- 전역 pub wrapper도 dart를 PATH에서 찾는다. 로컬 실행은 `mise exec dart@3.13.3 -- <command>`.
- Markdown에 dart format을 실행하지 않는다.
- pub.dev 업로드 성공 직후 설치 목록 전파가 지연될 수 있다. 동일 버전을 재게시하지 않는다.
- GLM `--effort high`가 코드·문서 리뷰에 안정적이었다. `--effort medium`은 한 번 garbled 출력을 냈다.
- 리뷰 패킷은 `--diff <base>` 범위가 초점이 맞았다. 후속 리뷰는 직전 커밋을 base로 delta만 보냈다.
- **analyzer API는 설치된 소스(격리 캐시)에서 확인한다.** 14.3.0은 클래스 멤버가 `node.members`에서
  `node.body.members`(ClassBody·EnumBody)로 옮겨갔다. 추측으로 쓰면 `dart analyze`가 undefined_getter로 잡는다.
- **sandbox에서 `dart pub get`은 온라인으로 격리 PUB_CACHE에 받는다**(`--offline`은 빈 캐시에서 exit 69,
  호스트 `~/.pub-cache`는 의도적으로 차단). `package_config.json`이 격리 경로로 다시 써진다.
  `dart test --coverage`는 VM service(로컬 포트)가 차단되어 가벼운 테스트 한 개로도 hang한다.

## Next Steps

1. 실제 branch/status/log를 확인하고 루트 및 작업 경로의 AGENTS.md를 읽는다.
2. **0.3.0이 릴리스됐다**(main `92826d0`, pub.dev latest 0.3.0, 태그 v0.3.0·GitHub Release 공개,
   새 캐시 설치 확인). 미릴리스 변경은 없으므로 완료된 구현·배포를 반복하지 않는다.
3. 감사 backlog의 릴리스 전 처리 목록은 모두 처리됐다(`fix/pre-release-backlog`). 남은 후보는
   **선택 과제**(code_graph nodes hoist, FactCache 미주입, ReachabilityResult 미export, metrics
   tolerance 문서, analyzer 버전 캐시 키, query --baseline dead file, PRD 비교표 README)와
   enum과 같은 계열인 **extension type의 `.values` 공백 확인**이다.
4. 새 사용자 요청이 없다면 닫은·보류 항목은 위 근거를 먼저 읽고 다시 도출하지 않는다.

## Resume Prompt

Open this repository at `/Users/jinhongan/Desktop/dartograph`, read `HANDOFF.md` and applicable
`AGENTS.md` files, then continue from: `Verify current Git state. Product 0.3.0 is released
(main 92826d0, PR #19; pub.dev latest 0.3.0, tag v0.3.0 and GitHub Release published, fresh-cache
install verified). This session merged the audit backlog top four (bridge channel declaration order,
.values enum-constant false positive, empty channel name, dead --since diff.relative) as PR #18 and
the 0.3.0 release as PR #19; there are NO unreleased changes. GLM review via packet-review approved
both the main and delta passes. Local line coverage cannot run in the sandbox (VM service blocked);
CI check-coverage.sh covers it on two SDKs. The remaining audit backlog and the closed/deferred
lists were assessed deliberately; read the rationale before re-flagging. Follow the next explicit
user task.`

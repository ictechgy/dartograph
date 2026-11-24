# Handoff

_Last updated: 2026-11-22 (4차: 대표 라이브러리 보존 루트·`public-libraries:` 한계·rules 설정 줄·열, PR #165 독립 리뷰 반영)_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(PR #164 시점 원문은 그 파일 끝 절).

## Current Status

- 발행본은 **0.17.0**이다(pub.dev, GitHub Release `v0.17.0`, `dartograph_analysis_plugin` 0.1.1).
  `main`의 `Unreleased`에는 PR #161(`4bd0370`), PR #163(`88dd0ee`), PR #164(`7da8267`, 설정 오류·
  패키지 루트 진단, Refs #160)가 있다. 아직 발행하지 않았다.
- 브랜치 `ccr-37904670-hxdjsx`를 `origin/main` `7da8267`에서 다시 시작했다(이전 PR은 스쿼시 머지).
  푸시·PR은 코디네이터가 한다. 어느 커밋까지 푸시됐는지와 CI 상태는 이 문서에 적지 않는다.
  코디네이터가 `65c3e43`까지를 PR [#165](https://github.com/ictechgy/dartograph/pull/165)로 올렸다.
  - `6dd7ded` 대표 라이브러리 루트, `87674a8` `public-libraries:` 한계, `82d0e4c` rules 설정 줄·열,
    `65c3e43` HANDOFF. 각 수정 커밋의 중간 상태도 포맷·`dart analyze --fatal-infos`가 깨끗했다.
  - 그 위에 독립 리뷰(차단 2·nit 3) 반영 `858e490`, 재검토(should-fix 1·nit 2) 반영 커밋 하나(아래
    "PR #165 독립 리뷰 반영"·"재검토 반영"). 이력을 다시 쓰지 않았다.

## 이번 브랜치의 변경

세 수정 모두 `origin/main`을 네이티브 바이너리로 컴파일해 먼저 재현했다. 같은 바이너리 쌍으로
pub cache의 게시 패키지 65개 코퍼스를 비교했다(아래 "코퍼스 델타").

### 1. export만 하는 대표 라이브러리가 dead 파일이었다

- 재현: `lib/p1.dart`가 `export 'src/a.dart';`뿐인 패키지에서 `dead`가
  `lib/p1.dart: warning: file package:p1/p1.dart — no reachable declaration or reachable library import`
  로 종료 1이었다. `dead --explain package:p1/src/a.dart::a`는 `retentionReason: publicApi`(그
  파일이 export해서 보존), `dead --explain package:p1/p1.dart`는 `reachable: false`였다. 한 실행에서
  보존 근거인 파일이 미도달이다. 파일 도달성은 "도달한 선언을 담거나 도달한 라이브러리가
  import·export하는 라이브러리"인데, 대표 라이브러리를 import하는 것은 패키지 밖 소비자라
  그래프에 없다.
- 수정: `_assembleResult`가 공개 이름을 하나라도 export하는 대표 라이브러리(`publicApi` 후보가 있는
  라이브러리, `--workspace` 멤버 포함) 자체를 `publicApi` 보존 루트로 더한다. 처음에는 "분석 계층이
  이미 지원하던 라이브러리 루트"라고 적었는데, 그 근거(`a library retention root is not also reported
  as dead`)는 간선 없는 정점 하나의 테스트였다. 실제로는 선언 도달 BFS가 루트 라이브러리의
  import·export를 따라가 그 대상을 '선언을 담은 라이브러리'로 시드해 explain·query 근거가 틀렸다.
  리뷰 반영에서 고쳤다(아래). `--closed-app`은 publicApi 루트를 빼므로 이 루트도 빠진다.
  publish_to로 가르지 않았다. 앱도 export한 선언을 이미 publicApi로 보존해 왔고, 그 전제를 걷어내는
  옵션이 `--closed-app`이다. 공개 이름을 export하지 않는 대표 라이브러리(`hide`로 모두 숨김,
  `library;`만)는 근거가 없으므로 전처럼 보고한다. 캐시 신원 v33.
- 결과: 대표 라이브러리가 `retentionRootsChecked`에 하나 더 실린다(baseline 지문은 id·kind라
  그대로다, 옛 baseline으로 새 `dead`를 돌려 확인). 대표 라이브러리가 import·export하는 라이브러리도
  도달한 파일이 된다. 그 라이브러리의 쓰이지 않는 선언은 계속 보고된다.
- 테스트: `test/cli/entry_library_cli_test.dart`(실제 analyzer, 4개: 게시 패키지·앱의 `dead`와
  `--explain`, `--closed-app`, 공개 이름 없는 대표 라이브러리). `pub_workspace_test`의 루트 삽입 순서
  기대값에 루트·멤버 대표 라이브러리 셋을 더했다.
- 옛 동작을 기대하던 기존 테스트 셋을 고쳤다. 리뷰에서 이 결정을 다시 볼 수 있게 적는다.
  - `closed_app_cli_test`는 라이브러리 모드에서 배럴(`lib/closed_app_fixture.dart`)이 "내부 import가
    없어 dead-file로 남는다(기존 의미)"고 단언했다. 결정 문서는 없고, `--closed-app` 도입 때 관측한
    동작을 적은 것이다. 이제 라이브러리 모드는 finding 0·종료 0이고, `--closed-app`에서 배럴이
    보고된다는 단언을 더했다.
  - `dead_cli_test`의 include/exclude 테스트는 "public_api.dart는 내부 참조가 없어 dead-file"이라는
    주석과 달리 실제로는 배럴 finding의 근거 목록에 `public_api.dart`가 실려 통과하던 테스트다.
    주석이 참이 되도록 세 실행에 `--closed-app`을 줬다.
  - `incremental_cli_test`는 배럴의 dead 파일 finding으로 종료 1을 만들던 fixture라, 아무도 import하지
    않는 `lib/legacy.dart`를 더해 같은 단언(종료 1, package:/project: ID)을 유지했다.
  - README 데모(`tool/record_demo.py`)의 `dead --closed-app` finding은 바뀌지 않는다. 같은 데모의
    `impact`·`query`는 `--closed-app` 없이 돌아 `fixtures/closed_app`의 `public-libraries:` 줄
    (`lib/used.dart`)이 복수형에서 단수형으로 바뀐다(구·신 바이너리로 확인). 기록된 cast(2026-09)는
    이 한계가 생기기 전 녹화라 그 줄이 아예 없다. 다시 녹화할지는 별도 판단이다.

### 2. `public-libraries:` 한계가 보존된 선언도 셌다

- 재현: build.yaml builder factory만 있는 `lib/builder.dart`, `@pragma('vm:entry-point')` 함수만 있는
  `lib/annotated.dart`가 `public-libraries: lib/annotated.dart, lib/builder.dart are public libraries …
  ones used only by package consumers are reported as unreachable`로 세졌다. 두 파일의 선언은 하나도
  보고되지 않는다. `retained_files: [lib/testing.dart]`로 한계의 권고를 따라도 한계가 남았다.
- 원인: 술어가 `retentionRoots[id] != publicApi`라 다른 근거의 루트를 미보존으로 셌고, 계산이
  build.yaml·설정 보존 루트보다 앞에 있었다.
- 수정: 모든 루트가 정해진 뒤(설정 보존 다음)에 세고, 술어를 "어떤 루트도 아님"으로 바꿨다.
  라이브러리가 하나면 `… is a public library outside …; its declarations …`로 적는다(단수 문법).
  이 술어는 최상위 선언만 봐서, 멤버를 보존하지 않는 루트(pragma 등)의 클래스 멤버가 보고되는데도
  한계를 뺐다. 리뷰 반영에서 공개 멤버까지 보게 고쳤다(아래).
- 테스트: `public_libraries_test`에 2개(builder·pragma·`main`·`retained_files`로 보존된 파일은 빼고
  단수 문구, 보존 선언과 미보존 선언이 섞인 파일은 센다). builder 사례는 package config을 둔다.
  package config이 없으면 builder ID(`package:widgets/builder.dart::…`)를 찾지 못해 실제로
  미도달이 되므로 세는 것이 맞다.

### 3. rules 설정 진단의 줄·열

- 재현: `rules --config`에 중복 키가 있는 YAML을 주면 `Analysis failed: invalid rules configuration:
  Duplicate mapping key.`뿐이었다(`dartograph.yaml`·pubspec 진단은 줄·열을 싣는다). 이전 HANDOFF의
  "작은 후속" 항목이다.
- 수정: 줄·열 붙이기를 `core/config_source.dart`의 `describeConfigurationError`로 옮겨 두 진단이
  같이 쓴다. `… Duplicate mapping key. (line 3, column 5)`. 종료 코드 2, 경로 미반향은 그대로다.
- 테스트: `phase5_cli_test`에 1개.

### 회귀 테스트가 수정 없이 실패하는지

- `origin/main` 코드에 새 테스트를 얹으면 5개가 실패한다(대표 라이브러리 2, public-libraries 1,
  rules 1, workspace 루트 순서 1). 나머지 새 테스트(`--closed-app`, 공개 이름 없는 대표 라이브러리,
  섞인 파일)는 이미 맞는 동작을 지킨다.
- 변형 5개가 각각 실패시킨다: 대표 라이브러리 루트 제거(3개 실패), 술어를 `!= publicApi`로 되돌림,
  한계 계산을 설정·builder 루트 앞으로 되돌림, 단수 분기 제거, rules 진단을 `exception.message`로
  되돌림. 캐시 신원 갱신은 테스트로 고정하지 않았다(기존 관례).

### 적대 입력 (구·신 바이너리 비교)

`dead`·`--closed-app`·`--report-test-only`·`--report-override-only`로 16개 사례를 비교했다.
바뀐 것은 모두 예상한 것뿐이다.

- 대표 라이브러리가 더는 보고되지 않음: 의존 패키지 이름만 다시 export(`export 'package:meta/meta.dart'
  show immutable`), 조건부 export, part를 가진 대표 라이브러리(part의 미사용 비공개 선언은 계속 보고),
  앱(`publish_to: none`, `--closed-app`에서는 전처럼 보고), export 사슬(사슬 끝의 미사용 선언은 계속
  보고), 자기 패키지 `package:` URI export, 테스트가 `src/`만 import, `@override` 멤버.
- 쓰이지 않는 import: 대표 라이브러리가 import만 하고 쓰지 않는 `src/helper.dart`는 파일 finding이
  빠지고 선언 finding(`Helper`)은 남는다. 도달한 라이브러리가 import하는 파일은 dead 파일이 아니라는
  기존 파일 규칙 그대로다(지우면 대표 라이브러리가 컴파일되지 않는다).
- 바뀌지 않음: 이름이 패키지와 다른 `lib/api.dart`, analysis options가 뺀 대표 라이브러리,
  `hide`로 모두 숨긴 대표 라이브러리, `library;`만 있는 대표 라이브러리.
- `public-libraries:`: `// dartograph:ignore`로 보존된 파일은 빠지고, `retained_names`가 일부만 보존한
  파일은 남는다(단수 문구).
- `query`·`compare`(양쪽 모두 루트라 루트 diff에 없음)·`baseline`(옛 baseline 재사용) 확인.

### 코퍼스 델타

pub cache의 게시 패키지 65개(이전 세션의 51개 + 14개)에 package config을 만들어(같은 이름의 최신
캐시 버전, pub 해석과 같지 않음) `dead`와 `dead --closed-app`(51개만)을 구·신 바이너리로 비교했다.

- 새로 보고된 finding 0, 종료 코드가 1 → 0이 된 패키지 2(`json_annotation`, `chopper_generator`:
  대표 라이브러리 dead 파일 하나가 유일한 finding이었다).
- 빠진 finding 6: 위 둘의 대표 라이브러리, `test_api`의 `test_api.dart`·`hooks.dart`, `test_core`의
  `test_core.dart`·`scaffolding.dart`(`hooks.dart`·`scaffolding.dart`는 대표 라이브러리가 export하는
  최상위 라이브러리다). `--closed-app` finding은 바뀌지 않았다.
- `public-libraries:` 문구가 단수로 바뀐 패키지 8(`args`·`charcode`·`cli_util`·`glob`·`matcher`·
  `node_preamble`·`shelf`·`http`, 셈은 같다).
- build.yaml을 가진 패키지 3개(`source_gen`·`retrofit_generator`·`pubspec_parse`)도 비교했다. finding
  변화 0이고, `source_gen`은 `lib/builder.dart`에 보존 루트가 아닌 공개 클래스(`CombiningBuilder`)가
  있어 계속 센다. 수정 2의 효과는 코퍼스가 아니라 위 재현(builder·annotation·`retained_files`만 있는
  파일)으로 확인했다.

## PR #165 독립 리뷰 반영

리뷰는 차단 2·should-fix 0·nit 3을 냈다. 리뷰어의 fixture는 지워져 설명대로 다시 만들었고, 각 항목을
`origin/main`(`7da8267`)·`65c3e43`·수정본 네이티브 바이너리로 비교했다.

### 차단 1: 대표 라이브러리가 import·export하는 파일의 explain·query 근거

- 원인: 선언 도달 BFS가 루트가 된 대표 라이브러리의 import·export 간선을 따라가 그 대상 라이브러리를
  선언 도달 집합에 넣었다. 파일 도달성은 그 집합의 라이브러리 ID를 '도달한 선언을 담은 라이브러리'로
  선언 witness보다 먼저 시드했으므로, export한 파일은 witness를 잃고 import만 한 파일은
  `contains a reachable declaration`(거짓, 같은 실행이 그 파일의 유일한 선언을 보고한다)과 경로
  `[파일]`을 받았다. `query`의 `reachability.path`도 루트에서 시작하지 않았다.
- 수정(`reachability_analyzer.dart`): 선언 BFS는 보존 루트인 라이브러리(`::` 없는 `package:`·
  `project:` ID)의 간선을 펼치지 않는다. 그 import·export는 라이브러리 BFS가 실제 `(previous, edge)`로
  따라간다. 시드는 선언 witness를 먼저, 라이브러리 ID를 `putIfAbsent`로 나중에 한다. 경로가 도달한
  자기 선언이 없는 루트 라이브러리에서 시작하면 이유는 `reachable from a retained library`다. 재정의 루트 증분
  고정점(`_enableReachedOverrideRoots`)도 같은 규칙을 쓴다.
  - 처음에는 라이브러리 ID 모양이면 모두 펼치지 않게 했다가 `override_only_differential_test`가
    실패했다. 그 무작위 그래프는 라이브러리 정점에도 아무 종류의 간선을 붙이는데, 증분 고정점은 그
    정점을 펼치고 기준 구현(`analyze`)은 펼치지 않아 어긋났다. 실제 그래프의 라이브러리 정점에는
    import·export 간선만 있고(이 저장소 그래프 10,960개 간선으로 확인) 루트가 아닌 라이브러리는 선언
    BFS에 들어오지 않으므로, 루트만 건너뛰는 규칙이 실제 그래프에서 같은 결과를 내면서 합성 그래프의
    기존 의미를 지킨다. 결과적으로 루트가 아닌 라이브러리는 `origin/main`처럼 선언 도달 집합에 없어
    `query`의 상태·witness도 `origin/main`과 같다.
- 전후(`dead --explain`):

  | 대상 | `origin/main` | `65c3e43` | 수정 후 |
  |---|---|---|---|
  | `p11_ownimp`의 import만 한 `src/unused_imported.dart` | `[entry, file]`, import 간선, witness `Own` | `[file]`, 간선 없음, `contains a reachable declaration` | `origin/main`과 같음 |
  | `p1`의 export된 `src/a.dart`, 이 저장소의 `src/core/code_graph.dart` | witness `a`·`CodeGraph` | witness 없음 | witness 복원 |
  | 순수 배럴 `p7`이 import만 한 `src/helper.dart` | 미도달 | `[file]`, `contains a reachable declaration` | `[p7.dart, helper.dart]`, import 간선, `reachable from a retained library` |

  `query`의 path도 같다(`[entry, file]`). export 사슬·조건부 export·part를 가진 대표 라이브러리·`bin/`에서
  닿는 사슬 7개 파일을 비교해 `origin/main`에서 도달하던 파일은 모두 `origin/main`과 같은 답이었다.
  finding은 `65c3e43`과 같다.
- 테스트: `entry_library_cli_test`에 3개(export한 파일의 witness, import만 한 파일의 explain·query,
  자기 선언이 있는 대표 라이브러리가 import한 파일의 witness·query), `reachability_analyzer_test`에
  1개(라이브러리 루트의 import·export). 넷 다 `65c3e43`에서 실패한다. 변형 셋(BFS 건너뛰기 제거, 시드
  순서 되돌림, 새 이유 제거)이 각각 실패시킨다. 재정의 고정점 쪽 건너뛰기는 실제 그래프에서 관측
  차이가 없어(라이브러리 정점의 간선은 import·export뿐) 따로 고정하지 않았다.

### 차단 2: 멤버가 보고되는데 `public-libraries:`가 빠짐

- 원인: 술어가 최상위 선언만 보고 아무 루트나 받았다. publicApi는 공개 멤버까지 루트로 삼지만
  pragma·`dartograph:ignore`·`retained_names`·`@visibleForTesting`·builder·plugin 루트는 멤버를
  보존하지 않는다.
- 수정: 공개 최상위 선언과 공개 멤버(이름의 어느 마디도 `_`로 시작하지 않음, 익명 extension 표식은
  한 마디)가 모두 루트일 때만 뺀다. enum 상수는 enum으로 구조 보존되므로 보지 않는다.
  `retained_files`는 멤버까지 루트로 삼으므로 따로 다루지 않는다. 캐시 신원 v34.
- 전후(`origin/main` → `65c3e43` → 수정 후): `p10_pragma`(pragma 클래스의 `now`)·`p10_ignore`
  (`dartograph:ignore` 클래스와 extension)·`p10_names`(`retained_names: [FakeClock]`)는 finding이 셋
  다 그대로인 채 한계가 있음 → 없음 → 있음(단수). `retained_files`·builder factory만·pragma 함수만·
  pragma enum은 있음 → 없음 → 없음. 비공개 멤버만 있는 pragma 클래스(`Hook._internal` 보고)는 있음 →
  없음 → 없음(소비자가 쓸 수 없는 멤버다).
- 테스트: `public_libraries_test`에 1개(pragma 클래스·ignore extension·`retained_names` 클래스를 센다,
  `65c3e43`에서 실패), 기존 '세지 않음' 테스트에 `retained_files` 클래스 멤버·pragma enum·비공개
  멤버만 있는 pragma 클래스를 더했다. 변형 둘(최상위만 보기, enum 상수 포함)이 각각 실패시킨다.
- 문서: CHANGELOG(.ko)의 "None of those declarations is reported as unreachable"와 README(.ko)의
  "retained by nothing"을 실제 규칙으로 고쳤다.

### nit

1. 열 단위: `describeConfigurationError`의 열은 UTF-16 코드 단위다(`abc`·`😀😀` 키에서 11·12열,
   `dartograph.yaml` 진단과 같다). 닫히지 않은 따옴표 문자열은 yaml 파서가 멈춘 파일 끝(마지막 줄 다음
   줄 1열)을 짚는다(`dartograph.yaml`도 같다). USAGE·TROUBLESHOOTING·CHANGELOG(.ko)·함수 주석에 적었다.
2. 데모: 위 1절의 문장을 고쳤다(`impact`·`query`의 `public-libraries:` 줄이 단수형으로 바뀐다).
3. `--workspace`의 `public-libraries:`는 루트 pubspec만 본다. 루트가 `publish_to: none`이고 게시할 수
   있는 멤버의 `lib/wb_other.dart`(`p9_ws`)는 세지 않는다(`origin/main`·수정본 같음, 멤버를 따로
   분석하면 센다). 범위 밖이라 Next Steps에 남겼다.

### 리뷰 반영 검증

- 실행 환경: 테스트·바이너리 실행은 `HOME`을 스크래치로 두고(`PUB_CACHE=/root/.pub-cache`) 돌려 실제
  `~/.cache/dartograph`를 건드리지 않았다(실행 전후 항목 수 2,350 그대로).
- Dart 3.13.3: 포맷 변경 없음, `dart analyze --fatal-infos` 깨끗. 일반 테스트(`-j 2`,
  `--exclude-tags=global_activation`) 1,230 통과·22 건너뜀·실패 0(`self_analysis_test` 포함), 이 실행만의
  제품 라인 커버리지 12,585/13,413(93.83%). 첫 실행에서 `override_only_differential_test`가 실패해
  차단 1의 규칙을 루트 라이브러리로 좁혔다(위). 오탐 코퍼스·analyzer 경계 통과, CLI 계약 243 ok.
  `global_activation`은 `65c3e43`에서 상한 없이 통과한 뒤 설치 경로가 바뀌지 않아 다시 돌리지 않았다.
- Dart 3.11.0(analyzer 14.5.0) worktree: 포맷·analyze 깨끗, 관련 테스트 136개 통과.
- 새 테스트 다섯(`entry_library` 3, `reachability_analyzer` 1, `public_libraries` 1)은 `65c3e43` 코드에서
  모두 실패한다. 변형 다섯(BFS 건너뛰기 제거, 시드 순서 되돌림, 새 이유 제거, 최상위만 보기, enum 상수
  포함)이 각각 하나 이상을 실패시킨다.
- 코퍼스(65개, `dead` 65·`--closed-app` 51, 큰 두 패키지를 뺀 63개 패키지의 라이브러리 2,429개에 대한
  `query --batch`):
  - `65c3e43` → 수정본: finding·종료 코드·limitation 변화 0. `query` 경로 21개가 바뀌었다. 모두
    `65c3e43`이 `[파일]`로 잘못 시드하던 라이브러리이고 이제 실제 간선 경로다(예: `test_api`의
    `hooks.dart` `[hooks.dart]` → `[test_api.dart, hooks.dart]`, `file`의 `interface.dart` →
    `[common.dart, interface.dart]`).
  - `origin/main` → 수정본: 빠진 finding 6·종료 1 → 0 두 패키지(처음 보고와 같음), limitation은 단수
    문구만. `query` 2,429개 중 2,363개는 `origin/main`과 같다. 57개는 대표 라이브러리가 `retained`
    (`publicApi`, 경로 `[entry]`)가 됐고, 3개는 대표 라이브러리를 거치던 경로가 그 루트에서 시작하게
    짧아졌고, 6개는 이번에 빠진 finding의 파일이 실제 경로로 도달했다.

## 재검토 반영 (`858e490` 위)

재검토는 두 차단이 고쳐졌고(explain·query가 모든 경계 사례에서 참, finding 불변, v34 필요·충분)
should-fix 1·nit 2를 냈다.

- should-fix: `public-libraries:`가 part의 선언을 보지 못했고 이 PR이 그 공백을 축소로 바꿨다.
  `lib/x.dart`(`part 'src/x_part.dart'; @pragma('vm:entry-point') void hook() {}`)와 part의
  `class FakeX { void m() {} }`에서 세 빌드 모두 `FakeX`·`FakeX.m`을 보고한다. `origin/main`은 x.dart를
  셌지만 이유는 pragma로 보존된 `hook`이 publicApi가 아니어서였고(x.dart 자기 유닛만 봤다),
  `65c3e43`·`858e490`은 `hook`이 루트라 세지 않았다. part로만 된 라이브러리는 `origin/main`도 놓쳤다.
  원인은 술어가 그 파일 유닛의 정점만 본 것이다.
  - 수정: 유닛을 `librarySource`(part는 호스트 라이브러리)로 묶어 라이브러리마다 자기 유닛과 part 유닛을
    함께 본다. 그래서 최상위 `lib/` 아래 part 파일은 라이브러리로 따로 싣지 않고 그 선언을 호스트에
    돌린다(`origin/main`은 `lib/z.dart, lib/z_part.dart`처럼 part 파일을 라이브러리로 실었다). 캐시 신원
    v35.
  - 전후(`origin/main` → `858e490` → 수정 후): part에 보고될 클래스가 있는 `x.dart`는 셈 → 안 셈 →
    셈, part로만 된 `y.dart`는 안 셈 → 안 셈 → 셈, 모두 pragma로 보존된 최상위 part(`z_part.dart`)는
    `z.dart, z_part.dart` → 없음 → 없음. finding은 셋 다 같다.
- nit 1: CHANGELOG(.ko)의 `reachable from a retained library` 조건을 "대표 라이브러리에 자기 선언이
  없으면"에서 "자기 선언이 하나도 도달하지 않으면"(쓰이지 않는 비공개 선언만 있는 경우 포함)으로 고쳤다.
- nit 2: 센 라이브러리에 익명 extension이 있으면 권고 끝에 `; an unnamed extension cannot be exported,
  so retain its file with retained_files`를 붙인다. `origin/main`의 최상위 판정은 익명 extension
  표식(`<unnamed-extension@project:lib/ext.dart#0>`)의 점 때문에 그것을 세지 못했고, `858e490`부터 센다.
- 선택 항목: 재정의 고정점이 라이브러리 루트의 간선을 펼치지 않는 규칙을 단위 테스트로 고정했다
  (라이브러리 → 선언 간선이 있는 합성 그래프, 반복 정의와 같은 결과). 그 건너뛰기를 지우면 실패한다.
- 테스트: `public_libraries_test`에 2개(part 선언을 호스트로 셈·최상위 part 파일 이름 안 실음, 익명
  extension 권고)는 `858e490`에서 실패한다. `override_only_differential_test`에 1개(위 고정, `858e490`에도
  있는 규칙이라 통과하고 건너뛰기를 지우면 실패). 변형 둘(호스트 자기 유닛만 보기, 익명 extension 표시
  제거)이 각각 실패시킨다.
- 익명 extension만 있는 `ext.dart`: `origin/main` 안 셈 → `858e490` 셈 → 셈 + 위 안내.
- 검증: 포맷 변경 없음, `dart analyze --fatal-infos` 깨끗(3.13.3·3.11.0). 일반 테스트(3.13.3, `-j 2`)
  1,233 통과·22 건너뜀·0 실패, 이 실행의 커버리지 12,596/13,421(93.85%). 관련 테스트 `-j 1`은
  3.13.3 69개(`self_analysis_test` 포함)·3.11.0 81개 통과. CLI 계약 243 ok. AOT 자기 분석은 위와 같다.
  코퍼스(`dead` 65·`--closed-app` 51)는 `858e490`과 finding·종료 코드·limitation 변화 0이다(part로
  갈리는 라이브러리가 없다). 실제 `~/.cache/dartograph`는 2,350개 그대로다.
- 기록만 하는 것(`origin/main`도 같고 보수적인 쪽): 보존된 sealed 클래스의 하위 타입이나 annotation이
  붙은 멤버로만 살아 있는 클래스(`class Hooks { @pragma('vm:entry-point') static void hook() {} }`)는
  보고될 것이 없어도 센다. 구조 보존·컨테이너 보존은 루트가 아니어서다.

## 이슈 #160 (`Analysis failed: unable to index the package.`)

- 제보 본문은 비어 있다(제목만). 2026-11-04 저장소 계정 댓글(설치 방법·`which dart`·
  `dart --version`·Flutter 여부)에 2026-11-22까지 답이 없다. 새 댓글은 사용자 승인 뒤에만 단다.
  제보자 확인 전에는 이슈를 닫지 않는다(PR은 `Refs #160`).
- 지금까지 고친 같은 문구의 원인(SDK 탐색, 읽기 불가 디렉터리, 잘못된 설정, 없는 루트 등)과 재현되지
  않은 경우, 제보자에게 물을 것은 HANDOFF-HISTORY의 PR #164 시점 원문 절에 있다. 이번 브랜치는
  #160과 관계없다.

## 검증

- 도구: 이 컨테이너에 Dart가 없어 이전 세션이 내려받아 둔 SDK(3.13.3·3.11.0)를 썼다. `packet-ask`도
  없어 GLM 리뷰는 받지 못했다. 공유 호스트의 부하 평균이 18~25였다.
- Dart 3.13.3(analyzer 14.7.0), 메인 클론: 포맷 변경 없음, `dart analyze --fatal-infos` 깨끗.
  `tool/check-coverage.sh`와 같은 두 단계를 `-j 2`·`-j 1`로 돌렸다.
  - 일반 테스트: 1,209 통과·22 건너뜀·16 실패. 2개는 옛 배럴 동작을 기대하던 `closed_app_cli_test`·
    `dead_cli_test`(위 "옛 동작을 기대하던 기존 테스트", 실행 뒤 고침)이고, 14개는 30초 시간
    초과였다(`dup`·`deps`·`cli_contract`·`runtime`·`mcp_server`·`sdk_below_minimum`·`incremental_cli`·
    `build_config_cache`·`fact_cache`·`incremental_analysis`·`evidence_mutation`). 그 13개 파일을
    `-j 1`로 다시 돌려 131 통과, 남은 둘(고친 `dead_cli_test`, 다시 시간 초과한
    `build_config_cache_test`)을 단독으로 돌려 8/8 통과했다.
  - `global_activation` 태그는 11분 상한에서 시간 초과(검증 메모의 컨테이너 현상)라
    `tool/verify-global-activation.sh`를 상한 없이 돌려 통과했다(설치본 CLI 계약 239 ok, 19분 32초).
  - 제품 라인 커버리지 12,569/13,404(93.77%, 시간 초과 포함 합산, 기준 90%).
  - 오탐 코퍼스·analyzer 경계 통과, CLI 계약 243 ok. `dart pub publish --dry-run`은 세 수정 커밋
    뒤(HANDOFF만 수정된 트리, HANDOFF는 게시 패키지에서 빠진다) 경고 0이다.
- Dart 3.11.0(analyzer 14.5.0), 별도 worktree: 포맷 변경 없음, analyze 깨끗, 관련 테스트 112개
  (`entry_library`·`public_libraries`·`phase5`·`pub_workspace`·`incremental_cli`·`closed_app`·
  `dead_cli`·`project_configuration` 둘·`reachability_analyzer`) 통과. 세 수정 커밋으로 둔 깨끗한
  worktree에서 `dart pub publish --dry-run` 경고 0.
- 자기 분석: 일반 테스트의 `self_analysis_test`(제품 finding 0, 모듈 의존 방향, 모듈 간 순환 없음)
  통과. AOT 바이너리의 `dead`는 `origin/main`과 같은 테스트 fixture 파일 finding 1개
  (`test/index/fixture/lib/platform.dart`), `rules --strict --config tool/module_layers.yaml` 위반 0,
  `cycles --level file`은 cli 모듈 안(`dartograph_cli` ↔ `mcp_server`)뿐이다.
- 정리: 시간 초과한 `build_config_cache_test`가 teardown 뒤에도 돌며 다시 만든
  `/tmp/dartograph-build-incremental.*` 2개를 지웠다. 이번 테스트 실행이 `~/.cache/dartograph`에 쓴
  항목 182개(이 세션에 쓴 파일만 담은 디렉터리)도 지웠다(아래 Next Steps).

## 검증 메모

- `verify_global_activation_test`(11분 상한)는 작업 컨테이너에서 시간 초과로 실패한 적이 있다.
  PR CI에서는 통과해 왔다(`pub global` 래퍼 경유 호출당 약 2.3초). 상한 없이 직접 돌린
  `tool/verify-global-activation.sh`는 통과했다.
- 권한 테스트는 root에서 건너뛴다. root에서 검증하려면 `setpriv --bounding-set
  -dac_override,-dac_read_search --inh-caps=-all dart test …`로 돌린다. CI 러너는 비root다.
- 공유 호스트에서 부하가 높으면 30초 기본 제한을 넘는 테스트가 나온다. 시간 초과만으로
  실패를 판정하지 말고 단독(`-j 1`) 재실행으로 구분한다. 호스트 git이 2.43이면 부분 클론 테스트
  13개는 건너뛴다(CI에서 돈다).
- Dart 3.11.0은 analyzer 14.5.0, 3.13.3은 14.7.0을 해석한다. 3.11.0 검증은 lock이 바뀌므로 별도
  worktree에서 한다.
- 이 컨테이너의 사용 가능 디스크가 2 GB 안팎까지 줄었다(다른 작업과 공유). 커버리지 원시 파일은
  테스트 파일당 1 MB 안팎이다.

## 리뷰 절차의 대체

AGENTS.md는 PR마다 GLM 리뷰(`packet-ask`)를 요구한다. 이 환경에는 `packet-ask`가 없어 이번 브랜치도
GLM 리뷰를 받지 못했다. PR을 열면 코디네이터가 독립 리뷰를 받거나, GLM을 쓸 수 있는 환경에서
이 delta를 리뷰한다.

## Next Steps

- 푸시는 코디네이터가 한다. 두 SDK CI와 CI에서만 확실히 도는 `global_activation` 태그·커버리지
  90% 게이트 결과를 PR에서 확인한다.
- 다음 릴리스(0.18.0 후보)는 CONTRIBUTING 절차를 따른다. 게시 전에 이슈 #160에 수정 버전을
  안내할지 사용자에게 확인한다.
- 이번에 찾았지만 뺀 것:
  - 대표 라이브러리가 아닌 export 전용 최상위 라이브러리(예: `collection`의 `lib/algorithms.dart`)는
    게시 패키지에서도 dead 파일로 보고되고, 자기 선언이 없어 `public-libraries:`에도 세지지 않는다.
    한계에 셀지(새 출력)나 보존할지는 대표 라이브러리 밖 공개 라이브러리 보존을 넓히지 않기로 한
    기존 결정과 맞물린다.
  - `rules --config` 진단은 `dartograph.yaml` 진단과 달리 반향하는 설정 문장을 400 rune으로 자르지
    않는다(긴 키 이름이 그대로 실린다).
  - 일반 테스트 한 번이 실제 사용자 캐시 `~/.cache/dartograph`에 임시 루트마다 새 항목을 남긴다(이번
    실행에서 137개 증가, 이 컨테이너에 2,395개가 쌓여 있었다). 임시 패키지를 분석하는 CLI·`dart run`
    테스트가 `userCacheEnvironment`나 `XDG_CACHE_HOME`을 격리하지 않는다. test/AGENTS.md의 "격리
    캐시" 규칙과 맞지 않으므로 테스트 쪽 후속이다.
  - `build_config_cache_test`가 시간 초과하면 teardown 뒤에도 본문이 돌아 증분 캐시 디렉터리를 다시
    만든다(`/tmp/dartograph-build-incremental.*`가 남는다).
  - `--workspace`에서 `public-libraries:`는 루트 pubspec의 `publish_to`·이름만 본다. 게시할 수 있는
    멤버의 다른 최상위 라이브러리는 세지 않는다(PR #165 리뷰 nit 3, 기존 동작).
  - README 데모 cast는 `public-libraries:` 한계가 생기기 전 녹화다. 다시 녹화하면 `impact`·`query`
    출력에 그 줄이 생긴다.
  - `public-libraries:`는 보존된 sealed 클래스의 하위 타입, annotation 붙은 멤버로만 살아 있는 클래스처럼
    보고될 것이 없는 파일도 센다(구조·컨테이너 보존은 루트가 아니다, `origin/main`도 같다, 보수적).
- 일부러 뺀 후속 항목. 보존을 좁히거나 계약을 바꾸는 변경이라 근거와 결정이 먼저 필요하다.
  - 다음 셋은 보존을 좁히므로, 반대 방향 코퍼스와 실제 프로젝트 델타가 먼저 있어야 한다.
    - 문서 주석 참조(`/// [Foo]`)를 사용 간선에서 빼기
    - 조건부 구성의 import 폐쇄 축소
    - 생성 코드 루트의 조건부화
  - typedef 정점화(미사용 typedef 보고, `query` 지원): 새 판정이 생긴다.
  - `generated_files` 설정 키: 단위 사실 캐시 키 설계가 필요하다.
  - 0.15.0~0.16.1 게시본은 analyzer 제약이 `<15.0.0`이라 새로 설치하면 14.6·14.7로 해석될 수
    있다. 옛 게시본을 retract할지는 게시 권한이 있는 환경에서 판단한다.
  - `runtime --execute`의 dart 실행 파일 탐색은 SDK 탐색과 공유하지 않았다. 목적이 다르고
    모듈 경계 문제도 있다. 그쪽도 `FLUTTER_ROOT`를 보게 할지는 별도로 판단한다.
  - 원인을 분류하지 못한 실패의 진단(`unable to index the package`)에 예외 종류 같은 단서를
    싣거나 디버그 환경 변수를 두는 것은 출력 계약·경로 미반향 원칙과 맞물려 사용자 결정이 필요하다.
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화는 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. 발행본은 0.17.0이고 `main`
`7da8267`까지의 `Unreleased`는 미발행이야. 브랜치 `ccr-37904670-hxdjsx`의 4차 수정(대표 라이브러리
보존 루트, `public-libraries:` 한계, rules 설정 줄·열)과 PR #165 리뷰 반영 커밋이 푸시됐는지와 CI는
GitHub에서 확인해줘.
릴리스는 지시가 있을 때 CONTRIBUTING 절차를 따라. #160은 Refs로만 연결돼 있으니 제보자 확인 전에는
닫지 말고, 새 댓글은 승인 뒤에만 달아. Next Steps의 제외 항목은 근거 없이 착수하지 마.

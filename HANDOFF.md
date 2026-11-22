# Handoff

_Last updated: 2026-11-22 (4차: 대표 라이브러리 보존 루트·`public-libraries:` 한계·rules 설정 줄·열)_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(PR #164 시점 원문은 그 파일 끝 절).

## Current Status

- 발행본은 **0.17.0**이다(pub.dev, GitHub Release `v0.17.0`, `dartograph_analysis_plugin` 0.1.1).
  `main`의 `Unreleased`에는 PR #161(`4bd0370`), PR #163(`88dd0ee`), PR #164(`7da8267`, 설정 오류·
  패키지 루트 진단, Refs #160)가 있다. 아직 발행하지 않았다.
- 브랜치 `ccr-37904670-hxdjsx`를 `origin/main` `7da8267`에서 다시 시작했다(이전 PR은 스쿼시 머지).
  푸시·PR은 코디네이터가 한다. 어느 커밋까지 푸시됐는지와 CI 상태는 이 문서에 적지 않는다.
  커밋은 아래 세 수정(대표 라이브러리 루트, `public-libraries:` 한계, rules 설정 줄·열)과 이 HANDOFF
  커밋이다. 각 수정 커밋의 중간 상태도 포맷·`dart analyze --fatal-infos`가 깨끗했다.

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
  라이브러리, `--workspace` 멤버 포함) 자체를 `publicApi` 보존 루트로 더한다. 라이브러리 루트는
  분석 계층이 이미 지원하던 형태다(`a library retention root is not also reported as dead` 테스트,
  explain의 `retained as a root`). `--closed-app`은 publicApi 루트를 빼므로 이 루트도 빠진다.
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
  - README 데모(`tool/record_demo.py`)는 `dead --closed-app`이라 출력이 바뀌지 않는다.

### 2. `public-libraries:` 한계가 보존된 선언도 셌다

- 재현: build.yaml builder factory만 있는 `lib/builder.dart`, `@pragma('vm:entry-point')` 함수만 있는
  `lib/annotated.dart`가 `public-libraries: lib/annotated.dart, lib/builder.dart are public libraries …
  ones used only by package consumers are reported as unreachable`로 세졌다. 두 파일의 선언은 하나도
  보고되지 않는다. `retained_files: [lib/testing.dart]`로 한계의 권고를 따라도 한계가 남았다.
- 원인: 술어가 `retentionRoots[id] != publicApi`라 다른 근거의 루트를 미보존으로 셌고, 계산이
  build.yaml·설정 보존 루트보다 앞에 있었다.
- 수정: 모든 루트가 정해진 뒤(설정 보존 다음)에 세고, 술어를 "어떤 루트도 아님"으로 바꿨다.
  라이브러리가 하나면 `… is a public library outside …; its declarations …`로 적는다(단수 문법).
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
보존 루트, `public-libraries:` 한계, rules 설정 줄·열)이 PR로 올라갔는지와 CI는 GitHub에서 확인해줘.
릴리스는 지시가 있을 때 CONTRIBUTING 절차를 따라. #160은 Refs로만 연결돼 있으니 제보자 확인 전에는
닫지 말고, 새 댓글은 승인 뒤에만 달아. Next Steps의 제외 항목은 근거 없이 착수하지 마.

# Handoff

_Last updated: 2026-11-25 (5차: `--workspace`·`source_packages` 파일 finding 경로, 멤버별 `public-libraries:` 한계, rules 진단 길이)_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(PR #165 시점 원문은 그 파일 끝 절).

## Current Status

- 발행본은 **0.17.0**이다(pub.dev, GitHub Release `v0.17.0`, `dartograph_analysis_plugin` 0.1.1).
  `main`의 `Unreleased`에는 PR #161(`4bd0370`), PR #163(`88dd0ee`), PR #164(`7da8267`), PR #165
  (`acda403`, 대표 라이브러리 보존 루트·`public-libraries:` 한계·rules 설정 줄·열)가 있다. 아직
  발행하지 않았다.
- 브랜치 `ccr-37904670-hxdjsx`를 `origin/main` `acda403`에서 다시 시작했다(이전 PR은 스쿼시 머지).
  푸시·PR은 코디네이터가 한다. 어느 커밋까지 푸시됐는지와 CI 상태는 이 문서에 적지 않는다.
  - 수정 커밋 셋(`d9d3f9a` 파일 finding 경로, `a869625` 멤버별 `public-libraries:`, `c0c5792` rules
    진단 길이)과 이 HANDOFF 커밋이다.

## 이번 브랜치의 변경

세 수정 모두 `origin/main`을 네이티브 바이너리(`dg-main`)로 컴파일해 먼저 재현했다. 수정 1만 넣은
바이너리(`dg-a`)와 셋 다 넣은 바이너리(`dg-new`)로 델타를 나눠 쟀다.

### 1. `--workspace` 멤버·`source_packages`의 dead 파일 finding 경로

- 재현: 루트(`publish_to: none`)와 멤버 `pkgs/a`(`lib/testing.dart`에 `FakeCore`)가 있는 workspace에서
  `dead --workspace --format text`가
  `lib/testing.dart: warning: file package:a/testing.dart — …`를 냈다. 같은 실행의 선언 finding은
  `pkgs/a/lib/testing.dart:1:1`, `query package:a/testing.dart`의 `location.path`는
  `project:pkgs/a/lib/testing.dart`였다. `source_packages: [packages/core]`도 같아서
  `package:core/orphan.dart`가 루트의 `lib/orphan.dart`(다른 파일)로 보고됐다.
- 원인: `ReachabilityAnalyzer`가 파일 finding의 source를 라이브러리 ID에서 만들며(`_librarySource`)
  `package:<name>/<path>`를 언제나 스캔 루트의 `lib/<path>`로 옮겼다. 색인은 라이브러리 정점에 실제
  경로(`sourceUri`)를 이미 싣는다.
- 수정: 선언 finding처럼 `node.sourceUri ?? _librarySource(node.id)`. 분석 계층만 바뀌므로 캐시
  신원은 그대로다(캐시된 그래프에 `sourceUri`가 있다). finding ID·baseline 지문(id·kind)도 그대로다
  (`dg-main`이 쓴 baseline을 `dg-new`가 읽어 8개 모두 억제됨을 확인).
- 영향받던 곳(모두 `finding.source`를 쓴다): text·GitHub Actions·SARIF·Markdown 위치, CODEOWNERS
  묶음(`dg-main`은 멤버 파일 finding을 모두 `*` 소유자로 묶었다), `include`/`exclude` glob,
  `--since`(`dg-main`은 루트 `lib/orphan.dart`만 바꿔도 멤버 파일 finding 셋을 그 변경에 넣었다),
  파일별 `source-*` 한계 매칭.
- 테스트: `reachability_analyzer_test` 1개(합성 그래프, 경로와 source 한계), 새
  `test/cli/member_file_findings_cli_test.dart` 3개(실제 analyzer: `--workspace`의 JSON·text·GitHub
  Actions, `exclude: ["pkgs/**"]`, `source_packages`). 넷 다 수정을 되돌리면 실패한다.

### 2. `--workspace`의 `public-libraries:` 한계를 멤버마다 센다

- 재현: 위 workspace에서 멤버를 따로 분석하면(`dead pkgs/a`) `public-libraries: lib/testing.dart is a
  public library outside lib/a.dart; …`가 나오는데, `dead --workspace`에는 이 줄이 없었다. 한계가
  루트 pubspec의 `publish_to`·이름과 `^lib/[^/]+\.dart$`만 봐서, 루트가 `publish_to: none`인 흔한
  workspace에서는 아예 나오지 않았다. 이전 HANDOFF의 "PR #165 리뷰 nit 3"이다.
- 수정: `_publicLibrariesLimitations`가 루트와 멤버마다 그 pubspec(`publish_to: none`이면 건너뜀)과
  대표 라이브러리(`<member>/lib/<name>.dart`)로 센다. 최상위 `lib/*.dart`는 앞 경로로 한 번에 묶어
  패키지마다 다시 훑지 않는다. 줄은 패키지당 하나, 루트 다음 멤버 경로순, 경로는 루트 기준이다.
  루트 문구는 그대로다. 캐시 신원 v36.
- 테스트: `public_libraries_test`의 `--workspace` 그룹 2개(루트 `publish_to: none`, 게시 가능한 루트가
  먼저). 멤버를 넘기지 않게 되돌리면 둘 다 실패한다.

### 3. rules 설정 진단의 반향 길이

- 재현: 5,000자 모르는 키가 있는 `rules --config`의 진단 줄이 5,066바이트였다. 같은 길이의
  `entry_points` 값을 가진 `dartograph.yaml` 진단은 400 rune + `…`(421바이트)이다. 이전 HANDOFF의 후속
  항목이다.
- 수정: `_reportRulesConfigInvalid`가 이스케이프 전에 `_shortenEchoed`를 적용한다. CODEOWNERS 내용
  오류는 고정 문구만 내므로 손대지 않았다.
- 테스트: `phase5_cli_test` 1개(381자 + `…`). 자르기를 빼면 실패한다.

### 적대 입력 (`dg-main` → `dg-new`)

`dead --format json`(필요하면 `--workspace`)으로 비교했다. 픽스처 생성 스크립트는 세션 스크래치에
있었고 저장소에 넣지 않았다.

- 바뀌지 않음: 루트 안 다른 디렉터리를 가리키는 `lib/link.dart` 링크(선언·파일 모두 링크 경로),
  루트 밖을 가리키는 링크, 공백이 든 파일 이름(`a%20b.dart` → `lib/a b.dart`), package config 없음
  (`project:` ID), part를 가진 고아 라이브러리(호스트 경로), `retained_files`로 멤버 파일 보존 +
  대표 라이브러리 export로 보존한 멤버(종료 0, 한계 없음).
- 바뀜(의도): 중첩 멤버(`pkgs/a`, `pkgs/a/sub`)는 파일 finding 경로가 각 멤버 경로가 되고 한계가 두
  줄(`pkgs/a/lib/extra.dart, pkgs/a/lib/orphan.dart …`, `pkgs/a/sub/lib/orphan.dart …`), 멤버의 파일이
  섞이지 않는다. workspace + `source_packages`는 `vendor/core` 경로가 바로잡히고 게시하지 않는
  `vendor/core`는 세지 않는다. 대표 라이브러리가 없는 멤버, `publish_to: https://…` 멤버는 센다
  (단독 분석과 같다). 건너뛴 멤버(pubspec 없음)는 줄이 없다. 멤버의 최상위 part·pragma 함수만 있는
  라이브러리·익명 extension은 단독 분석과 같은 문구(익명 extension 안내 포함)다.
- `--since`·CODEOWNERS·Markdown·SARIF는 위 1절. 같은 캐시를 `dg-main` → `dg-new` 순서로 써도 v36
  덕에 새 줄이 나오고, 두 번째 실행(캐시 적중)과 `--incremental` 두 번(파일 변경 포함)이 전체
  분석과 바이트 같다.

### 코퍼스 델타

- 단일 패키지: pub cache의 게시 패키지 75개(이름마다 최신 버전, `analyzer`·`_fe_analyzer_shared`
  제외)에 캐시 패키지 전부를 담은 package config을 손으로 만들어(pub 해석과 같지 않음)
  `dead`·`dead --closed-app`을 비교했다. `dg-main` → `dg-a` 150건, `dg-main` → `dg-new` 150건 모두
  종료 코드와 stdout이 바이트 단위로 같다(단일 패키지에는 루트 밖 패키지 라이브러리가 없고, 루트의
  `public-libraries:` 계산은 그대로다).
- workspace: 같은 캐시의 게시 패키지 30개를 멤버(`pkgs/<name>`, `resolution: workspace`)로 둔
  workspace(루트 `publish_to: none`)에서 `dead --workspace`를 비교했다. 26개 finding의 ID·종류·수와
  다른 한계는 같다. 바뀐 것은 `collection` 멤버의 export 전용 최상위 라이브러리 파일 finding 다섯
  (`project:lib/algorithms.dart` → `project:pkgs/collection/lib/algorithms.dart` 등, 수정 1)과 새
  `public-libraries:` 줄 여섯(`args`·`cli_util`·`glob`·`http`·`matcher`·`shelf`, 수정 2)뿐이다. 멤버
  30개를 각각 단독으로 분석한 `public-libraries:` 줄에 멤버 경로를 붙이면 workspace의 여섯 줄과 정확히
  같다. `collection`의 다섯 파일은 자기 선언이 없어 세지 않는다(아래 "남긴 것"의 export 전용 최상위
  라이브러리).

## 이슈 #160 (`Analysis failed: unable to index the package.`)

- 제보 본문은 비어 있다(제목만). 2026-11-04 저장소 계정 댓글에 답이 없다. 새 댓글은 사용자 승인
  뒤에만 단다. 제보자 확인 전에는 이슈를 닫지 않는다(PR은 `Refs #160`). 이번 브랜치는 #160과
  관계없다. 원인별 정리는 HANDOFF-HISTORY의 PR #164 시점 원문 절에 있다.

## 검증

- 도구: 이 컨테이너에 Dart가 없어 이전 세션이 내려받아 둔 SDK(3.13.3·3.11.0)를 썼다. `packet-ask`도
  없어 GLM 리뷰는 받지 못했다. 공유 호스트의 부하 평균이 17~37이었다. 테스트·바이너리 실행은 `HOME`을
  스크래치로 두고(`PUB_CACHE=/root/.pub-cache`) 돌려 실제 `~/.cache/dartograph`(2,350개)를 건드리지
  않았다.
- Dart 3.13.3(analyzer 14.7.0), 메인 클론: `dart format --output=none --set-exit-if-changed .` 변경 없음,
  `dart analyze --fatal-infos` 깨끗(두 중간 커밋 `d9d3f9a`·`a869625`에서도 깨끗).
  - `tool/check-coverage.sh`를 그대로 한 번 돌렸을 때는 부하 37에서 30초 시간 초과가 32개 났다(모두
    `TimeoutException`, 뒤따른 오류는 시간 초과한 본문이 teardown 뒤에 낸 것). 그 실행을 멈추고 같은
    일반 단계를 `dart test -j 2 --timeout=4x --exclude-tags=global_activation --coverage=…`로 다시 돌려
    1,240 통과·22 건너뜀·실패 0(62분, `self_analysis_test` 셋 포함)이다. 이 단계만의 제품 라인
    커버리지는 12,610/13,435(93.86%, 기준 90%)다. CI는 기본 시간 제한으로 돈다.
  - `global_activation` 태그: 테스트(11분 상한)는 이 컨테이너에서 시간 초과였다(검증 메모의 현상). 같은
    스크립트 `tool/verify-global-activation.sh`를 상한 없이 돌려 통과했다(설치본 CLI 계약 239 ok,
    21분 58초). 그래서 두 단계를 합산한 커버리지는 이 환경에서 내지 못했다(CI가 낸다).
  - 오탐 코퍼스(`tool/verify-false-positive-corpus.sh`)·analyzer 경계 통과. CLI 계약
    (`tool/verify-cli-contract.sh`, 스스로 컴파일해 SDK 탐색 4건 포함) 243 ok·실패 0.
    `dart pub publish --dry-run`은 이 HANDOFF 커밋 뒤 깨끗한 트리에서 경고 0이다(HANDOFF는 게시 패키지에서
    빠진다).
- Dart 3.11.0(analyzer 14.5.0), 별도 worktree(`c0c5792`): 포맷 변경 없음, `dart analyze --fatal-infos`
  깨끗, 관련 테스트 118개(`reachability_analyzer`·`member_file_findings`·`public_libraries`·`phase5`·
  `pub_workspace`·`entry_library`·`source_packages`·`dead_cli`·`closed_app`·`codeowners`·
  `project_configuration`, `-j 1 --timeout=4x`) 통과.
- 회귀 테스트가 수정 없이 실패하는지: 새 테스트 7개 중 수정 1의 넷은 `_librarySource(node.id)`로
  되돌리면, 수정 2의 둘은 멤버를 넘기지 않게(`const []`) 되돌리면, 수정 3의 하나는 `_shortenEchoed`를
  빼면 실패한다(각각 확인).
- 자기 분석(AOT 바이너리, `dg-main`과 `dg-new` 결과가 바이트 단위로 같다): `dead`는 테스트 fixture
  파일 finding 1개(`test/index/fixture/lib/platform.dart`, 이전과 같음), `rules --strict --config
  tool/module_layers.yaml` 위반 0, `cycles --level file`은 cli 모듈 안(`dartograph_cli` ↔ `mcp_server`)
  하나뿐이다.

## 검증 메모

- `verify_global_activation_test`(11분 상한)는 작업 컨테이너에서 시간 초과로 실패한 적이 있다.
  PR CI에서는 통과해 왔다. 상한 없이 직접 돌린 `tool/verify-global-activation.sh`는 통과했다.
- 권한 테스트는 root에서 건너뛴다. root에서 검증하려면 `setpriv --bounding-set
  -dac_override,-dac_read_search --inh-caps=-all dart test …`로 돌린다. CI 러너는 비root다.
- 공유 호스트에서 부하가 높으면 30초 기본 제한을 넘는 테스트가 나온다. 시간 초과만으로
  실패를 판정하지 말고 단독(`-j 1`) 재실행으로 구분한다. 호스트 git이 2.43이면 부분 클론 테스트
  13개는 건너뛴다(CI에서 돈다).
- Dart 3.11.0은 analyzer 14.5.0, 3.13.3은 14.7.0을 해석한다. 3.11.0 검증은 lock이 바뀌므로 별도
  worktree에서 한다.
- 테스트·바이너리 실행은 `HOME`을 스크래치로 두고 돌린다. 일반 테스트 한 번이 실제 사용자 캐시에
  임시 루트마다 항목을 남기기 때문이다(아래 Next Steps).

## 리뷰 절차의 대체

AGENTS.md는 PR마다 GLM 리뷰(`packet-ask`)를 요구한다. 이 환경에는 `packet-ask`가 없어 이번 브랜치도
GLM 리뷰를 받지 못했다. PR을 열면 코디네이터가 독립 리뷰를 받거나, GLM을 쓸 수 있는 환경에서
이 delta를 리뷰한다.

## Next Steps

- 푸시는 코디네이터가 한다. 두 SDK CI와 CI에서만 확실히 도는 `global_activation` 태그·커버리지
  90% 게이트 결과를 PR에서 확인한다.
- 다음 릴리스(0.18.0 후보)는 CONTRIBUTING 절차를 따른다. 게시 전에 이슈 #160에 수정 버전을
  안내할지 사용자에게 확인한다.
- 이번에 보고 남긴 것:
  - 대표 라이브러리가 아닌 export 전용 최상위 라이브러리(예: `collection`의 `lib/algorithms.dart`)는
    게시 패키지에서도 dead 파일로 보고되고, 자기 선언이 없어 `public-libraries:`에도 세지지 않는다.
    사용자 결정이 필요한 항목이다(대표 라이브러리 밖 공개 라이브러리 보존을 넓히지 않기로 한 기존
    결정과 맞물린다). 이번 수정 1로 workspace에서는 그 finding의 경로만 바로잡혔다.
  - `source_packages`의 패키지는 대표 라이브러리 보존도 `public-libraries:`도 적용하지 않는다(로컬
    path 의존성을 앱 내부 코드로 본다, 기존 동작). 게시하는 로컬 패키지를 그렇게 다룰지는 별도 판단이다.
  - 일반 테스트 한 번이 실제 사용자 캐시 `~/.cache/dartograph`에 임시 루트마다 새 항목을 남긴다.
    임시 패키지를 분석하는 CLI·`dart run` 테스트 30여 파일이 `userCacheEnvironment`나
    `XDG_CACHE_HOME`을 격리하지 않는다. test/AGENTS.md의 "격리 캐시" 규칙과 맞지 않는 테스트 쪽
    후속이다(파일 수가 많아 이번 범위에서 뺐다).
  - `build_config_cache_test`가 시간 초과하면 teardown 뒤에도 본문이 돌아 증분 캐시 디렉터리를 다시
    만든다(`/tmp/dartograph-build-incremental.*`가 남는다).
  - 도움말의 CODEOWNERS 문단 "The file path is not echoed in errors."는 내용 오류 진단에만 맞다. 읽기
    실패 진단은 `--codeowners`로 받은 경로를 반향한다(`rules --config`의 읽기 실패도 같다). 문구를
    고칠지(도움말은 CLI 계약 테스트 대상)는 별도 판단이다.
  - README 데모 cast는 `public-libraries:` 한계가 생기기 전 녹화다. 다시 녹화하면 `impact`·`query`
    출력에 그 줄이 생긴다.
  - `public-libraries:`는 보존된 sealed 클래스의 하위 타입, annotation 붙은 멤버로만 살아 있는 클래스처럼
    보고될 것이 없는 파일도 센다(구조·컨테이너 보존은 루트가 아니다, 보수적).
- 일부러 뺀 후속 항목. 보존을 좁히거나 계약을 바꾸는 변경이라 근거와 결정이 먼저 필요하다.
  - 다음 셋은 보존을 좁히므로, 반대 방향 코퍼스와 실제 프로젝트 델타가 먼저 있어야 한다.
    - 문서 주석 참조(`/// [Foo]`)를 사용 간선에서 빼기
    - 조건부 구성의 import 폐쇄 축소
    - 생성 코드 루트의 조건부화
  - typedef 정점화(미사용 typedef 보고, `query` 지원): 새 판정이 생긴다.
  - `generated_files` 설정 키: 단위 사실 캐시 키 설계가 필요하다.
  - 0.15.0~0.16.1 게시본은 analyzer 제약이 `<15.0.0`이라 새로 설치하면 14.6·14.7로 해석될 수
    있다. 옛 게시본을 retract할지는 게시 권한이 있는 환경에서 판단한다.
  - `runtime --execute`의 dart 실행 파일 탐색은 SDK 탐색과 공유하지 않았다. 그쪽도 `FLUTTER_ROOT`를
    보게 할지는 별도로 판단한다.
  - 원인을 분류하지 못한 실패의 진단(`unable to index the package`)에 예외 종류 같은 단서를
    싣거나 디버그 환경 변수를 두는 것은 출력 계약·경로 미반향 원칙과 맞물려 사용자 결정이 필요하다.
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화는 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. 발행본은 0.17.0이고 `main`
`acda403`까지의 `Unreleased`는 미발행이야. 브랜치 `ccr-37904670-hxdjsx`의 5차 수정(workspace·
source_packages 파일 finding 경로, 멤버별 `public-libraries:`, rules 진단 길이)이 푸시됐는지와 CI는
GitHub에서 확인해줘. 릴리스는 지시가 있을 때 CONTRIBUTING 절차를 따라. #160은 Refs로만 연결돼
있으니 제보자 확인 전에는 닫지 말고, 새 댓글은 승인 뒤에만 달아. Next Steps의 제외 항목은 근거 없이
착수하지 마.

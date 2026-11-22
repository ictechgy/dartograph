# Handoff

_Last updated: 2026-11-22 (색인 실패 진단 개선 — 설정 오류·패키지 루트)_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(2026-11-16 원문은 그 파일 끝 절).

## Current Status

- 발행본은 **0.17.0**이다(pub.dev, GitHub Release `v0.17.0`, `dartograph_analysis_plugin` 0.1.1).
  `main`의 `Unreleased`에는 PR #161(`4bd0370`, #160 SDK 탐색·읽기 불가 디렉터리 등)과
  PR #163(`88dd0ee`, analyzer 14.6·14.7 검증, `sdk-below-minimum:`·`options-excluded-files:`
  한계, 캐시 키 보강)이 있다. 아직 발행하지 않았다.
- `main` `88dd0ee`의 CI·impact-precheck(push)·analyzer-freshness(2026-11-16 예약 실행)는 모두
  통과했다(2026-11-22 GitHub API로 확인). 이전 HANDOFF의 "analyzer-freshness가 `main`에서 실패"
  항목은 해소됐다.
- 브랜치 `ccr-37904670-hxdjsx`를 `origin/main` `88dd0ee`에서 다시 시작했다. 푸시·PR은
  코디네이터가 한다. 푸시 여부와 CI 상태는 이 문서에 적지 않는다.
  - `419448f` fix(cli): 프로젝트 설정 오류 진단과 impact·schema·routes 오진 수정.
  - `cbca659` fix(cli): 없는 경로·파일 패키지 루트 진단.
  - 이 HANDOFF 커밋.

## 이번 브랜치의 변경

두 수정 모두 #160과 같은 문구(`Analysis failed: unable to index the package.`)가 원인을 가리는
경로다. 발행본과 같은 코드(`origin/main`)를 네이티브 바이너리로 컴파일해 차가운 캐시에서
재현한 뒤 고쳤다.

### 1. 프로젝트 설정 오류 (`419448f`)

- 재현: `dartograph.yaml`의 `entry_points: [bin/missing.dart]`에서 `graph`·`dead`·`cycles`·
  `query`·`compare`·`metrics`·`deps`·`dup`·`baseline`이 모두 일반 문구로 끝났다. 색인은 원인을
  적은 `FormatException`(`entry_points file does not exist: …`)을 던지지만 CLI가 버렸다. 잘못된
  YAML, 목록이 아닌 `include:`, `source_packages` 오류, pubspec의 YAML·이름 오류, 멤버가 없는
  루트의 `--workspace`도 같았다.
- 오진: `impact`는 변경 목록 파싱 분기(`on FormatException` → `Invalid changed list`, 64)가
  색인 전체를 감싼 바깥 try에 있어 `--symbol`·`--since`·올바른 `--changed`에도 64로 답했다.
  `schema`·`routes`는 `source_packages` 오류를 "소스 경로의 제어문자"로 알렸다.
- 수정: `index/project_configuration.dart`의 `readProjectConfiguration`이 설정 해석의 형식 오류를
  고칠 파일을 짚는 `ProjectConfigurationException`(`FormatException` 상속)으로 바꾼다. YAML
  구문 오류에는 줄·열을 붙이고, 읽기 경계 거부(`InputRejectedException`)는 감싸지 않는다. CLI는
  `Analysis failed: <문장>`을 `escapeText`로 싣는다(rules 설정 진단과 같은 경계). impact의
  변경 목록 분기는 목록을 읽는 안쪽 try로 옮겼고, schema·routes는 이 타입을 제어문자 분기보다
  먼저 잡는다. 종료 코드는 2(impact의 이 경우만 64 → 2)다. 형식이 잘못된 `--changed` 목록은
  그대로 64다.
- 테스트: `test/cli/project_configuration_cli_test.dart`(실제 analyzer, 6개),
  `test/index/project_configuration_test.dart`(경계 단위, 6개). 수정 전 코드에서 CLI 6개가
  모두 실패했다. 진단 분기·이스케이프·impact 분기 위치·schema·routes 분기·YAML 위치·읽기 경계
  rethrow·workspace·pubspec·entry_points·source_packages 감싸기를 하나씩 되돌린 변형 12개가
  각각 실패시켰다.

### 2. 패키지 루트 (`cbca659`)

- 재현: 없는 경로·파일(`lib/main.dart`)·끊긴 링크를 루트로 넘기면 루트를 받는 분석 명령 20개
  형태가 모두 일반 문구로 끝났다. 없는 경로는 dart:io가 `PathNotFoundException`이 아닌 일반
  `FileSystemException`으로 던진다(3.11.0·3.13.3 실측, 권한 거부도 일반 예외).
- 수정: `project_files.dart`의 `canonicalPackageRoot`가 링크를 따라간 종류가 디렉터리가
  아니면 `PackageRootNotFoundException`을 던진다. 루트를 처음 해석하는 곳(색인, impact 입력
  캡처, bridges·schema, routes, language-traversal, runtime)이 쓴다. 진단은
  `Analysis failed: the package root was not found or is not a directory. Check the path, …`이며
  경로를 반향하지 않는다. 디렉터리 링크와 빈 문자열(작업 디렉터리) 루트는 그대로다.
- 테스트: `test/cli/package_root_cli_test.dart`(18개 명령 × 없는 경로·파일·끊긴 링크, 디렉터리
  링크 유지). 수정 전 세 경우 모두 실패, 진단 분기·종류 검사·색인·입력 캡처·bridges·runtime·
  routes·language-traversal 지점을 하나씩 되돌린 변형 8개가 각각 실패시켰다.

## 이슈 #160 (`Analysis failed: unable to index the package.`)

- 제보 본문은 비어 있다(제목만). 2026-11-04에 저장소 계정이 설치 방법(`dart install`/
  `dart pub global activate`), `which dart`, `dart --version`, Flutter 여부를 묻고 우회책을 안내한
  댓글을 이미 달았다. 이전 HANDOFF의 "후속 댓글은 승인 뒤에"는 이 댓글과 겹친다. 2026-11-22까지
  제보자 답은 없다. 새 댓글은 여전히 사용자 승인 뒤에만 단다.
- 같은 문구를 내는 원인으로 지금까지 확인하고 고친 것:
  1. AOT 설치본의 SDK 탐색 실패(PR #161).
  2. 분석 범위 안팎의 읽기 불가 디렉터리(PR #161).
  3. 잘못된 `dartograph.yaml`·pubspec·`--workspace`(이번 `419448f`).
  4. 없는 경로·파일 루트(이번 `cbca659`, `.`을 넘긴 제보와는 맞지 않는다).
- 이번에 재현되지 않은 것(0 종료): `pub get`을 하지 않은 패키지, pubspec 없는 디렉터리, 끊긴
  링크(`lib/` 안·루트·`linux/flutter/ephemeral/.plugin_symlinks`), 디렉터리 링크 순환, 끊긴
  `analysis_options.yaml`·`dartograph.yaml`·`pubspec.yaml` 링크, Latin-1 바이트 소스, 깨진
  `analysis_options.yaml`.
- 제보자에게 물을 것(승인 시): 이미 물은 네 가지에 더해 `dartograph --version`, 패키지 루트에
  `dartograph.yaml`이 있는지, 같은 디렉터리에서 `dartograph graph --format json .`과
  `dart analyze`가 성공하는지. 미발행 수정을 써 볼 수 있으면
  `dart pub global activate --source git https://github.com/ictechgy/dartograph`로 설치해 새 진단
  문구를 받아 달라고 한다(일반 문구가 남으면 분류하지 못한 원인이라는 뜻이다).

## 검증

- 도구: 이 컨테이너에 Dart가 없어 이전 세션이 내려받아 둔 SDK(3.13.3·3.11.0, 각각
  `version` 파일과 `dart --version`으로 확인)를 썼다. `packet-ask`도 없어 GLM 리뷰는 받지 못했다.
- Dart 3.13.3(analyzer 14.7.0), 코드 커밋 `cbca659`, 메인 클론: 포맷 변경 없음, `dart analyze
  --fatal-infos` 깨끗, `tool/check-coverage.sh`와 같은 두 단계(공유 호스트라 `-j 2`·`-j 1`)에서
  일반 테스트 1,203 통과·22 건너뜀·실패 0, `global_activation` 1 통과, 제품 라인 커버리지
  12,554/13,384(93.80%). 오탐 코퍼스·analyzer 경계·CLI 계약(243 ok) 통과. `pub publish
  --dry-run`은 실행 중에 고친 문서 파일 하나 때문에 경고 1이었고, HANDOFF 커밋 뒤 깨끗한
  트리에서 다시 돌려 경고 0이었다(HANDOFF는 게시 패키지에서 빠진다).
- Dart 3.11.0(analyzer 14.5.0), 같은 코드의 별도 worktree: 포맷 변경 없음, analyze 깨끗, 일반
  테스트 1,202 통과·22 건너뜀·1 실패. 실패는 부하 평균 10 안팎에서 30초를 넘긴
  `build_config_cache_test`의 시간 초과(뒤이은 불일치 포함)였고, 단독(`-j 1`) 재실행에서 3/3
  통과했다. 새 테스트 16개는 3.11.0에서도 따로 돌려 통과했다. 오탐 코퍼스·analyzer 경계·CLI
  계약(243 ok)·`pub publish --dry-run`(경고 0) 통과.
- 권한 테스트(root에서는 건너뜀)는 `setpriv`로 `unreadable_directories_test`·
  `analyzer_graph_index_test`·`unanalyzed_directories_cli_test`·`package_root_cli_test`·
  `dartograph_cli_test`를 3.13.3에서 건너뜀 없이 돌려 통과했다. 도중에 호스트 디스크가 가득
  차(`No space left on device`) 한 번 실패해, 이 세션의 스크래치(커버리지 원시 파일·worktree)를
  지운 뒤 다시 돌렸다.
- 자기 분석: 일반 테스트의 `self_analysis_test`(제품 finding 0, 모듈 의존 방향) 통과. AOT
  바이너리로 따로 돌린 `dead`는 `test/index/fixture/lib/platform.dart` 파일 finding 1개였고,
  `origin/main` 바이너리도 같은 1개다(테스트 fixture, 기존). `rules --strict --config
  tool/module_layers.yaml`은 위반 0, `cycles --level file`의 순환은 cli 모듈 안
  (`dartograph_cli` ↔ `mcp_server`)뿐이다.

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

## 리뷰 절차의 대체

AGENTS.md는 PR마다 GLM 리뷰(`packet-ask`)를 요구한다. PR #161·#163에 이어 이번 브랜치도
`packet-ask`가 없는 환경이라 GLM 리뷰를 받지 못했다. PR을 열면 코디네이터가 독립 리뷰를 받거나,
GLM을 쓸 수 있는 환경에서 이 delta를 리뷰한다.

## Next Steps

- 푸시는 코디네이터가 한다. 두 SDK CI와 CI에서만 확실히 도는 `global_activation` 태그·커버리지
  90% 게이트 결과를 PR에서 확인한다.
- 다음 릴리스(0.18.0 후보)는 CONTRIBUTING 절차를 따른다. 게시 전에 이슈 #160에 수정 버전을
  안내할지 사용자에게 확인한다. 제보자 확인 전에는 이슈를 닫지 않는다(PR은 `Refs #160`).
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
  - `rules --config` 진단은 YAML 구문 오류의 줄·열을 싣지 않는다. 이번 `dartograph.yaml`과
    맞출지는 작은 후속이다(출력 문구 변경).
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화는 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. 발행본은 0.17.0이고 `main`
`88dd0ee`까지의 `Unreleased`는 미발행이야. 브랜치 `ccr-37904670-hxdjsx`의 색인 실패 진단 수정
(설정 오류·패키지 루트)이 PR로 올라갔는지와 CI는 GitHub에서 확인해줘. 릴리스는 지시가 있을 때
CONTRIBUTING 절차를 따라. #160은 Refs로만 연결돼 있으니 제보자 확인 전에는 닫지 말고, 새 댓글은
승인 뒤에만 달아. Next Steps의 제외 항목은 근거 없이 착수하지 마.

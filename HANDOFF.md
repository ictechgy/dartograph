# Handoff

_Last updated: 2026-11-15 (analyzer 14.6·14.7 검증, `sdk-below-minimum:` 한계)_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(2026-10-11 원문은 그 파일 끝 절).

## Current Status

- 이번 세션(2026-11-15)은 `origin/main` `a179b19`에서 만든 브랜치 `ccr-37904670-hxdjsx`에
  커밋 세 개를 쌓았다. 푸시·PR·댓글은 하지 않았다(지시 범위 밖). PR 본문 초안은 세션
  스크래치에 두었다.
  - `3deac5d` build(deps): analyzer 14.6·14.7 검증, 제약 `>=14.3.0 <14.8.0`, 검증 집합 `{3..7}`.
  - `995bdd8` feat(index): `sdk-below-minimum:` 한계. 분석 캐시 신원 `v31`, `pub_semver` 직접 의존.
  - 이 HANDOFF 커밋.
- 발행본은 **0.17.0**이다(pub.dev, GitHub Release `v0.17.0`, `dartograph_analysis_plugin` 0.1.1).
  준비했던 0.16.2는 게시하지 않고 0.17.0에 포함했다. CHANGELOG 0.16.2 절에 그렇게 표기돼 있다.
- `Unreleased` 변경을 담은 PR [#161](https://github.com/ictechgy/dartograph/pull/161)은
  2026-11-09에 `main`으로 스쿼시 머지됐다(`4bd0370`). 아직 발행하지 않았다(CHANGELOG `Unreleased`).
  아래 커밋 해시는 PR 브랜치의 것이며 `main`에는 `4bd0370` 하나로 합쳐졌다.
  독립 리뷰는 "수정 후 머지 가능" 판정이었고, 지적한 S1·S2·N1–N5를 반영했다(아래 절).
  `1d89990`은 코디네이터가 두 테스트를 Dart 3.11·3.13 포매터가 같은 모양으로 두도록 다듬은 커밋이다. 포맷 검사는 두 SDK 모두로
  돌린다(`dart format --output=none --set-exit-if-changed .`). toolVersion은
  0.17.0 그대로다. 분석 캐시 신원은 그 머지 시점에 `v30`이었고 이번 브랜치에서 `v31`이 됐다.
  - 오탐 수정(실제 analyzer fixture로 재현 후 수정): 필드 재정의, 감싼 선언의 annotation,
    두 인자 `vm:entry-point` pragma, 명시적 setter, typedef 사용, 구조적 보존 선언의 사용 간선
    고정점(enum 상수 인자 등), 공유 생성 파일 접미사, YAML plugin 진입점, 폰트·자산 의존.
  - 한계: `public-libraries:`, `unreadable-directories:`(#160).
  - 적합성 벡터를 isthmus `c76e105`로 다시 벤더링했고 `sql-relations` 14케이스를 실행한다.
  - CI: analyzer 하한(14.3)과 상한 밖 신규 마이너를 감지하는 예약 잡, impact-precheck 예시의
    push 게이트, `verify-cli-contract.sh`의 SDK 탐색 사례 4건.
  - 자기 분석: `tool/module_layers.yaml`로 모듈 의존 방향을 `rules --strict`로 검사하고,
    모듈 간 순환이 없음을 확인한다.

## analyzer-freshness 결과 (2026-11-15, `3deac5d`)

- 실패 재현: 상한을 푼 해석이 14.7.0을 고르고, 예약 잡 마지막 단계와 같은 셸이
  `newest analyzer 14.7.0, validated upper bound <14.6.0`으로 종료 1, 버전 계약 테스트가
  `14.7 ∉ {3, 4, 5}`로 실패했다.
- `doc/DECISION-analyzer.md` 「14.6.x·14.7.x 확장」 절에 근거를 남겼다. 요약하면 다음과 같다.
  - 5개 API 표면과 읽기 경계 표면은 생성자 선언 문법 말고 그대로다.
  - 14.7.0·14.6.0·14.3.0(`pub downgrade analyzer`) 사본에서 analyze·일반 테스트·오탐 코퍼스·
    경계 검사·CLI 계약이 통과했다. 14.6.0·14.3.0의 실패 2·9건은 모두 30초 시간 초과였고
    `-j 1` 재실행에서 통과했다(공유 호스트 부하 평균 20 안팎).
  - 14.7.0에서 HTTP route 오라클이 35개 중 일치 32·dynamic 3·불일치 0으로 기록과 같았다.
  - 14.6·14.7은 Dart `^3.13.0`을 요구한다. Dart 3.11.0은 넓힌 제약에서도 14.5.0을 고른다.
    그래서 CI에서 14.6을 해석하는 잡은 없다.
- 결과가 달라지는 analyzer 변경이 하나 있다. 14.6.0은 include한 옵션 파일의
  `analyzer: exclude:`를 다시 패키지 기준으로 해석한다(14.2–14.5 회귀 수정). 14.6부터 그
  패턴이 파일을 실제로 빼서, 그 파일에서만 쓰는 선언을 `dead`가 보고할 수 있다. 직접 쓴
  `exclude:`와 같은 결과이고 생성 파일은 계속 보존되므로 보정하지 않았다. 합성 패키지
  실측과 함께 README·CHANGELOG에 버전별 차이로 적었다.
- 넓힌 pubspec에서 같은 셸은 `<14.8.0`으로 종료 0이다. 예약 잡은 상한을 pubspec에서 읽으므로
  워크플로에는 범위 상수가 없다(3.11.0이 14.5를 해석한다는 주석만 고쳤다). 실제 예약 잡의
  통과는 푸시 뒤에 확인해야 한다.

## `sdk-below-minimum:` 한계 (`995bdd8`)

- 찾은 SDK의 `version`이 분석한 패키지(`--workspace`면 각 멤버) pubspec의 `environment.sdk`
  하한보다 낮으면 분석 명령이 한계를 더한다. 하한은 pub과 같은 `pub_semver` 규칙으로 비교하고
  파싱한 값(`>=3.13.0`, 배타 하한 `>3.13.0`)으로 적는다. 패키지 수를 세고 경로순 앞의 셋을
  싣는다. 오류가 아니며 finding·종료 코드는 그대로다.
- `environment.sdk`가 없거나 하한이 없는 제약, 읽지 못한 SDK 버전·제약은 비교하지 않는다.
  `runtime`·`routes`·`bridges`·`schema`에는 싣지 않는다(그래프 색인을 쓰지 않는다).
- 회귀 테스트: `test/index/sdk_below_minimum_test.dart`(실제 analyzer, 캐시 왕복, 워크스페이스),
  `test/cli/sdk_below_minimum_cli_test.dart`(finding·종료 코드 불변), 로케이터 단위 테스트.
  수정 전 실패와 세 가지 변형(조립 누락·멤버 누락·배타 하한)의 실패를 확인했다. CLI 계약
  스크립트에는 한계가 붙어도 `dead`가 0인 사례를 더했다.

## 이슈 #160 (`Analysis failed: unable to index the package.`)

- 제보에 환경 정보가 없어 제보자 환경과 일치하는지는 확인하지 못했다. 그래서 PR은
  `Refs #160`으로만 연결했고, 머지 뒤에도 이슈는 열려 있다(제보자 환경 미확인, 수정 미발행).
- 발행본 0.17.0 바이너리를 차가운 캐시에서 실행해 같은 문구가 나는 원인 두 가지를 재현했다.
  1. **SDK 탐색**: AOT 설치본(`dart install`, `dart compile exe`)은 VM이 아니다. 0.17.0은
     `PATH`의 진짜 `dart`로만 SDK를 찾았다. 다음 세 경우에는 analyzer가 실행 파일 근처를
     SDK로 추측했다가 `allowed_experiments.json`을 읽지 못해 실패했다.
     - `PATH`에 Flutter `bin/dart` 래퍼만 있을 때
     - `DART_SDK`만 설정했을 때
     - Windows에서 `dart.bat`만 있을 때

     데워진 캐시가 있으면 같은 실행이 성공해 증상이 들쭉날쭉했다.
  2. **읽기 불가 디렉터리**: 생성 파일 보충 순회가 루트 전체를 예외 처리 없이 훑었다. 그래서
     `android/.gradle` 아래 잠긴 디렉터리 하나만 있어도 색인 전체가 실패했다.
- 수정 내용
  - `index/dart_sdk_locator.dart`가 SDK를 다음 순서로 찾는다. 찾지 못하면 캐시를 읽기 전에
    `DartSdkNotFoundException`으로 멈춘다.
    1. 실행 중 VM
    2. `DART_SDK`
    3. `FLUTTER_ROOT/bin/cache/dart-sdk`
    4. `PATH`(Flutter 레이아웃과 `dart.bat` 포함)
    5. 실행 파일 옆 `dart-sdk`
  - 찾은 SDK의 `version`을 캐시 키에 넣는다.
  - 범위 밖 디렉터리에는 내려가지 않는다. 범위 안의 읽기 불가 디렉터리는 건너뛰고 수를 센다.
  - CLI는 SDK 부재와 권한 거부를 해결 방향이 담긴 문구로 알린다. 경로는 반향하지 않는다.
- 수정 전후 실측(차가운 캐시, 형제 `dart-sdk` 없는 위치의 바이너리)

  | 상황 | 0.17.0 | 수정본 |
  |---|---|---|
  | `PATH`에 dart 없음 | 2, 원인 불명 문구 | 2, SDK 부재 문구 |
  | Flutter 래퍼만 있음 | 2 | 0 |
  | `DART_SDK`만 설정 | 2 | 0 |
  | 데운 캐시 뒤 SDK 없음 | 0(가려짐) | 2 |
  | 형제 `dart-sdk` 배치 | 0 | 0 |
  | 범위 밖 잠긴 디렉터리(그래프 명령) | 2 | 0, 한계 없음 |
  | `lib/` 안 잠긴 디렉터리 | 2 | 0, `unreadable-directories: 1` |

  - 권한 실측은 `nobody` 사용자로 했다. root에서는 권한 비트가 강제되지 않으므로, 단위
    테스트는 권한이 강제되지 않으면 건너뛴다. CI 러너는 비root다.
  - 측정할 때 바이너리 옆에 `dart-sdk`를 두면 analyzer 기본값이 그것을 찾아 0.17.0도 성공한다.
    처음에 이 배치 때문에 잘못 측정했다. 이후 그 후보를 탐색 마지막에 유지해 회귀를 막았다.

## 독립 리뷰 반영 (PR #161)

- S1: 사실 캐시 키가 `skipped`만 넣고 `unreadable`을 넣지 않았다. 그래서 데워진 캐시가
  `unreadable-directories:` 한계를 숨기거나, 풀린 뒤에도 남겼다. 이제 루트 상대 경로를
  정렬해 키에 넣는다. 키 순회는 숨김 디렉터리를 가지치기하는데 생성 파일 보충은 `lib/.x/`에
  내려가는 차이도 있었다. 그래프 쪽을 좁히면 보존이 좁아지므로 키 쪽을 넓혔다. 재리뷰
  R1·R2에 따라 그 순회는 링크를 따라가지 않고(`_filePathsUnder`와 같은 규칙) 숨김 디렉터리
  아래 생성 파일만 더한다. 그래야 `.symlinks`·SDK 링크를 해시하지 않고, 그래프가 읽지 않는
  FIFO로 실패하지 않는다.
- S2: 공유 순회의 한계 출력(`bridges`·`schema`·`routes`)과 시작 디렉터리 재던짐 테스트를
  추가했다. `runtime`은 같은 순회를 쓰지만 전용 테스트는 없다.
- 권한 테스트는 root에서 `setpriv --bounding-set -dac_override,-dac_read_search --inh-caps=-all
  dart test …`로 돌리면 건너뛰지 않는다. 새 테스트는 모두 돌연변이 실패를 확인했다.
- N1–N4는 README·USAGE·CHANGELOG에 반영했다: 경로 기준 계수, `bridges`·`schema`의 루트 전체
  계수, `DART_SDK`·`FLUTTER_ROOT` 우선순위 변경, 실행 파일 기준 두 후보. SDK 버전이
  `environment.sdk` 하한보다 낮을 때의 한계(선택)는 넣지 않았다(Next Steps의 선택 후속 항목).

## 검증 메모

- `verify_global_activation_test`(11분 상한)는 이 세션의 작업 컨테이너에서 여러 번 시간
  초과로 실패했다. 하지만 PR CI의 `4d1a8d5` verify(3.11.0)·verify(3.13.3)는 이 테스트를
  포함해 전부 통과했다. 따라서 그 시간 초과는 컨테이너 특유의 현상이다(`pub global` 래퍼 경유
  호출당 약 2.3초. `origin/main`과 현재 트리가 같은 속도라 변경 탓이 아니다). 상한 없이
  직접 돌린 `tool/verify-global-activation.sh`는 238 ok로 통과했다.
- 권한 테스트를 root에서 검증하려면 `setpriv --bounding-set -dac_override,-dac_read_search
  --inh-caps=-all dart test …`로 돌린다.
- 2026-11-15 컨테이너는 다른 작업과 4코어를 나눠 부하 평균이 20 안팎까지 올랐다. 그때 일반
  스위트에서 30초 기본 제한을 넘는 테스트가 몇 개씩 나왔고, 모두 `-j 1` 재실행에서 통과했다.
  시간 초과만으로 실패를 판정하지 말고 단독 재실행으로 구분한다. 호스트 git이 2.43이라 부분
  클론 테스트 13개는 이 환경에서 건너뛴다(CI에서 돈다).
- 최종 커밋 `995bdd8`의 새 클론 검증(2026-11-15): Dart 3.13.3(analyzer 14.7.0 해석)은
  analyze 깨끗, 일반 테스트 1,162 통과·22 건너뜀·5 시간 초과(`-j 1` 재실행 통과), 코퍼스·경계·
  CLI 계약·`pub publish --dry-run`(경고 0) 통과. Dart 3.11.0(14.5.0 해석)은 일반 테스트 1,167
  통과·22 건너뜀·실패 0과 나머지 게이트 통과. 건너뛴 22개 중 권한 테스트 9개는 위 `setpriv`로
  14.7.0에서 따로 돌려 통과했다. `global_activation` 태그와 커버리지 게이트는 돌리지 않았다.
## 리뷰 절차의 대체

AGENTS.md는 PR마다 GLM 리뷰(`packet-ask`)를 요구한다. 이 세션에는 `packet-ask`가 없어
같은 세션의 독립 Claude 리뷰 에이전트로 대체했고, PR #161은 GLM 리뷰 없이 머지됐다. PR 본문과
머지 기록에 이 사실을 남겼다. GLM 리뷰를 다시 받을 수 있는 환경이면 이 PR의 delta를 후속 리뷰한다.
2026-11-15 브랜치도 `packet-ask`가 없어 GLM 리뷰를 받지 못했다. PR을 열면 그 delta를 리뷰한다.

## Next Steps

- 브랜치 `ccr-37904670-hxdjsx`를 푸시하고 PR을 열지는 사용자가 정한다. 열면 두 SDK CI와
  `analyzer-freshness`(workflow_dispatch)로 14.7.0 해석·하한 14.3 잡을 확인하고, CI에서만 도는
  `global_activation` 태그와 커버리지 90% 게이트 결과를 본다.
- `main` `4bd0370`의 CI(2026-11-10 확인): verify(3.11.0·3.13.3)·lowest-analyzer·fresh-upgrade는
  통과했다. 실패한 둘은 테스트 실패가 아니라 게이트 판정이다.
  - `impact-precheck`의 push 게이트(`--fail-on high`)가 큰 머지 diff에 risk high(81/100)로 실패했다.
  - `analyzer-freshness` 예약 잡의 `unvalidated-analyzer` 실패(14.7.0이 `<14.6.0` 밖)는 이번
    브랜치의 `3deac5d`가 다룬다. 머지 전까지 `main`에서는 계속 실패한다.
- 다음 릴리스(0.18.0 후보)는 CONTRIBUTING 절차를 따른다. 게시 전에 이슈 #160에
  수정 버전을 안내할지 사용자에게 확인한다.
- #160 제보자에게 OS·설치 방법(`dart install`/`pub global`)·`PATH`의 dart 위치를 묻는 후속 댓글은
  사용자 승인 뒤에 단다. 제보자 확인 전에는 이슈를 닫지 않는다.
- 후보(결정 필요): analyzer 14.6부터 include한 옵션 파일의 exclude도 적용되므로, 표준 소스
  디렉터리 안에서 `analysis_options.yaml` 제외로 빠진 비생성 Dart 파일 수를 한계로 세는 안.
  지금은 README에만 적었다. 출력이 바뀌는 새 한계라 이번 범위에서 뺐다.
- 일부러 뺀 후속 항목. 보존을 좁히거나 계약을 바꾸는 변경이라 근거와 결정이 먼저 필요하다.
  - 다음 셋은 보존을 좁히므로, 반대 방향 코퍼스와 실제 프로젝트 델타가 먼저 있어야 한다.
    - 문서 주석 참조(`/// [Foo]`)를 사용 간선에서 빼기
    - 조건부 구성의 import 폐쇄 축소
    - 생성 코드 루트의 조건부화
  - typedef 정점화(미사용 typedef 보고, `query` 지원): 새 판정이 생긴다.
  - `generated_files` 설정 키: 단위 사실 캐시 키 설계가 필요하다.
  - 0.15.0~0.16.1 게시본은 analyzer 제약이 `<15.0.0`이라 새로 설치하면 14.6·14.7로 해석될 수
    있다. 이번 검증은 현재 코드 기준이라 옛 게시본 코드가 그 버전에서 맞는지는 확인하지 않았다.
    옛 게시본을 retract할지는 게시 권한이 있는 환경에서 판단한다.
  - `runtime --execute`의 dart 실행 파일 탐색은 이번 SDK 탐색과 공유하지 않았다. 목적이 다르고
    모듈 경계 문제도 있다. 그쪽도 `FLUTTER_ROOT`를 보게 할지는 별도로 판단한다.
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화는 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. 발행본은 0.17.0이고,
`Unreleased` 변경과 #160 수정은 PR #161로 `main`에 스쿼시 머지됐어(`4bd0370`, 미발행, GLM 대신
독립 리뷰 에이전트로 리뷰). 브랜치 `ccr-37904670-hxdjsx`에는 analyzer 14.6·14.7 검증과
`sdk-below-minimum:` 한계 커밋이 있고 아직 푸시하지 않았어. 릴리스는 지시가 있을 때 CONTRIBUTING 절차를 따라.
#160은 Refs로만 연결돼 있으니 제보자 확인 전에는 닫지 마.
Next Steps의 제외 항목은 근거 없이 착수하지 마.

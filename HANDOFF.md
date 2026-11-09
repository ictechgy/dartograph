# Handoff

_Last updated: 2026-11-09 (독립 리뷰 반영 후)_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(2026-10-11 원문은 그 파일 끝 절).

## Current Status

- 발행본은 **0.17.0**이다(pub.dev, GitHub Release `v0.17.0`, `dartograph_analysis_plugin` 0.1.1).
  준비했던 0.16.2는 게시하지 않고 0.17.0에 포함했다. CHANGELOG 0.16.2 절에 그렇게 표기돼 있다.
- 브랜치 `ccr-37904670-hxdjsx`는 `[Unreleased]` 변경을 담은 PR
  [#161](https://github.com/ictechgy/dartograph/pull/161)이다. 독립 리뷰는 "수정 후 머지 가능"
  판정이었고, 지적한 S1·S2·N1–N5를 반영했다(아래 절). `1d89990`은 코디네이터가 두 테스트를
  Dart 3.11·3.13 포매터가 같은 모양으로 두도록 다듬은 커밋이다. 포맷 검사는 두 SDK 모두로
  돌린다(`dart format --output=none --set-exit-if-changed .`). toolVersion은
  0.17.0 그대로이고 분석 캐시 신원은 `v30`이다.
  - 오탐 수정(실제 analyzer fixture로 재현 후 수정): 필드 재정의, 감싼 선언의 annotation,
    두 인자 `vm:entry-point` pragma, 명시적 setter, typedef 사용, 구조적 보존 선언의 사용 간선
    고정점(enum 상수 인자 등), 공유 생성 파일 접미사, YAML plugin 진입점, 폰트·자산 의존.
  - 한계: `public-libraries:`, `unreadable-directories:`(#160).
  - 적합성 벡터를 isthmus `c76e105`로 다시 벤더링했고 `sql-relations` 14케이스를 실행한다.
  - CI: analyzer 하한(14.3)과 상한 밖 신규 마이너를 감지하는 예약 잡, impact-precheck 예시의
    push 게이트, `verify-cli-contract.sh`의 SDK 탐색 사례 4건.
  - 자기 분석: `tool/module_layers.yaml`로 모듈 의존 방향을 `rules --strict`로 검사하고,
    모듈 간 순환이 없음을 확인한다.

## 이슈 #160 (`Analysis failed: unable to index the package.`)

- 제보에 환경 정보가 없어 제보자 환경과 일치하는지는 확인하지 못했다. 그래서 PR은
  `Refs #160`이고 이슈를 닫지 않는다. 이슈에는 접수 댓글만 달았다.
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
  `environment.sdk` 하한보다 낮을 때의 한계(선택)는 넣지 않았다.

## 리뷰 절차의 대체

AGENTS.md는 PR마다 GLM 리뷰(`packet-ask`)를 요구한다. 이 세션에는 `packet-ask`가 없어
같은 세션의 독립 Claude 리뷰 에이전트로 대체한다. PR 본문과 머지 기록에 이 사실을 남긴다.
GLM 리뷰를 다시 받을 수 있는 환경이면 머지 뒤라도 이 PR의 delta를 후속 리뷰한다.

## Next Steps

- 머지 전: PR CI(Dart 3.11.0·3.13.3), 독립 리뷰 지적 확인. #160 제보자에게 OS·설치 방법
  (`dart install`/`pub global`)·`PATH`의 dart 위치를 묻는 후속 댓글은 사용자 승인 뒤에 단다.
- 머지 뒤: 다음 릴리스(0.18.0 후보)는 CONTRIBUTING 절차를 따른다. 게시 전에 이슈 #160에
  수정 버전을 안내할지 사용자에게 확인한다.
- 일부러 뺀 후속 항목. 보존을 좁히거나 계약을 바꾸는 변경이라 근거와 결정이 먼저 필요하다.
  - 다음 셋은 보존을 좁히므로, 반대 방향 코퍼스와 실제 프로젝트 델타가 먼저 있어야 한다.
    - 문서 주석 참조(`/// [Foo]`)를 사용 간선에서 빼기
    - 조건부 구성의 import 폐쇄 축소
    - 생성 코드 루트의 조건부화
  - typedef 정점화(미사용 typedef 보고, `query` 지원): 새 판정이 생긴다.
  - `generated_files` 설정 키: 단위 사실 캐시 키 설계가 필요하다.
  - 0.15.0~0.16.1 게시본은 analyzer 제약이 `<15.0.0`이라 새로 설치하면 미검증 14.6·14.7로
    해석될 수 있다. 옛 게시본을 retract할지는 게시 권한이 있는 환경에서 판단한다.
  - `runtime --execute`의 dart 실행 파일 탐색은 이번 SDK 탐색과 공유하지 않았다. 목적이 다르고
    모듈 경계 문제도 있다. 그쪽도 `FLUTTER_ROOT`를 보게 할지는 별도로 판단한다.
- 측정으로 기각한 프레임워크 보존 추가나 P7 최적화는 새 근거 없이 재개하지 않는다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. 발행본은 0.17.0이고,
`[Unreleased]` 변경과 #160 수정은 브랜치 `ccr-37904670-hxdjsx`의 PR로 리뷰 중이야(GLM 대신
독립 리뷰 에이전트를 쓴다). 머지 전이면 CI와 리뷰 지적을 확인하고, 머지 뒤 릴리스는
CONTRIBUTING 절차를 따라. #160은 Refs로만 연결돼 있으니 제보자 확인 전에는 닫지 마.
Next Steps의 제외 항목은 근거 없이 착수하지 마.

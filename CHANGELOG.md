# Changelog

## Unreleased

- `query`에 `--depth <n>`·`--limit <n>` 추가 (cartograph SymbolQueryDocument parity)
  - `--depth`(기본 1)는 사용 관계(`usedBy`·`dependsOn`)를 n단계까지 BFS로 따라가고, 각
    이웃의 `depth` 필드가 출발 심볼에서 몇 걸음인지 나타낸다. 한 이웃에 닿는 여러 간선
    종류를 `edges`에 모두 싣고, 여러 경로로 닿는 이웃은 최단 깊이 한 번만 보고한다
  - `--limit`은 방향별 이웃 수를 제한하며, 생략하면 해당 방향 `truncated`가 `true`가 되고
    생략된 이웃은 더 확장하지 않는다. 포함 관계(`members`·`declaredIn`)는 항상 한 단계다
  - 기본값(depth 1, limit 없음)에서 기존 출력을 byte-for-byte 보존한다. 1 미만·비정수·
    값 빠짐은 usage(64)다. `--batch`·`--baseline`과 함께 쓸 수 있다
- 입력 오류 메시지를 원인별로 구분해 원인을 반대로 가리키지 않게 수정
  - baseline 파일이 없으면 "unable to index the package" 대신 "Baseline is invalid:
    create it with dartograph baseline --write"를 낸다
  - `rules --config` 파일이 없거나 잘못되면 "Analysis failed: unable to read the rules
    configuration."을 낸다(인덱싱 실패와 구분, `Analysis failed:` 접두는 유지)
- 퍼센트 인코딩된 파일명의 dead file finding이 파일 수준 한계를 유지
  - `Uri.path`가 유지하는 `%20` 등을 디코딩해 analyzer가 실제 경로로 만든 source 한계와
    매치되게 한다. 이전에 그 파일의 한계가 finding에서 조용히 사라졌다
- Mermaid 출력이 자체 노드 ID의 `<`·`>`·`&`를 HTML 엔티티로 escape
  - DOT용 백슬래시 escape를 재사용해 `<no-library>`·`<unnamed-extension@...>`를 Mermaid가
    HTML 태그로 오해하던 문제를 고친다
- `--help`가 `--explain`이 `--format json`을 요구하고 `--baseline`·`--since`와 결합하지
  않음을 안내한다

## 0.3.0

- `.values`로만 소비되는 enum 상수의 미도달 오탐 수정
  - enum 상수는 enum→상수 `member` 간선만 있어 사용으로 치지 않고, 컨테이너 구제는
    멤버→컨테이너 단방향이라 상수를 살리지 못했다. `Status.values`처럼 개별 상수를
    직접 참조하지 않는 소비만 있으면 도달 가능한 enum의 상수까지 `dead`로 잘못 보고됐다
  - 이제 enum이 도달 가능하면 그 상수도 보존하고, `explain`은 `retained by its
    reachable enum` 근거와 enum까지의 실제 경로를 돌려준다. enum 자체가 미도달이면
    상수도 계속 보고한다
  - 노드 직렬화에 enum-상수 표시를 추가해 캐시 스키마를 v2로 올린다. 옛 캐시는
    decode에서 거부되어 재분석된다

- Flutter 채널 사실 추출의 조용한 누락·전면 실패 결함 수정
  - 클래스 등 선언 본문에서 `static final _channel = MethodChannel(...)`이 사용처보다
    뒤에 선언되면 method-invoke 사실이 통째로 누락되고 위치·심볼 없는
    `unresolved-receiver-invocations` 카운트로 강등됐다. 이제 선언 본문의 필드를 먼저
    훑어 선언 순서와 무관하게 해결한다. 동명 최상위 채널을 가리는 규칙은 유지된다
  - `MethodChannel('')`처럼 빈 채널·메서드 이름 한 줄이 `bridges` 출력 전체를 실패시키고
    파일·줄 정보도 남기지 않았다. 이제 그 사실만 건너뛰고 `empty-bridge-names` 한계로
    집계하며 나머지 사실은 정상 출력한다. 제어 문자가 든 이름은 계속 전면 거부한다

- `dead --since`가 `diff.relative=true`와 하위 패키지에서 변경 파일을 놓치던 문제 수정
  - `git diff`가 cwd 상대 경로를 출력하는데 저장소 루트와 join해 경로가 어긋나고
    발견이 전부 사라졌다(종료 0). 이제 `git`을 `-c diff.relative=false`로 실행해
    항상 저장소 루트 기준 경로를 쓴다

- 옵션 모양의 값을 경로로 받아들이던 문제 수정
  - `baseline --write --force .`은 `--force`라는 이름의 파일을 실제로 만들고 성공을 보고했다.
    이제 인덱싱과 쓰기 전에 usage 오류(64)로 거부한다
  - 값이 빠진 호출이 분석 실패(2)가 아니라 usage 오류(64)가 된다.
    `query`·`bridges`·`graph`의 패키지 루트, `rules --config`와 `dead --baseline`·`--since`의 값이 대상이다
  - `compare`는 `--`만 검사해 `compare -h .`처럼 실재하는 짧은 옵션을 경로로 받았다. 단일 대시도 거부한다
  - **좁은 파괴적 변경**: `-`로 시작하는 경로를 그대로 넘겨 동작하던 호출(예: `baseline --write -b.json .`)은
    이제 64다. `./-name`으로 바꿔 전달한다. `bridges`는 기존 `--` 이스케이프도 그대로 쓸 수 있다.
    문서화된 적 없는 암묵적 허용이었고, `query --batch`는 처음부터 같은 제약을 두고 있었다

- `dead --explain`이 멤버로 보존된 컨테이너를 미도달로 단정하던 문제 수정
  - 같은 실행의 `dead`가 발견에서 제외한 선언을 `explain`은 "unreachable from all
    retention roots"로 답하고 종료 코드 1을 냈다
  - 이제 `retained by a reachable member` 근거와 witness 멤버, 그 멤버까지의 실제
    경로를 함께 돌려주고 종료 코드 0을 낸다
  - `query`의 `retainedByMember` 상태와 `compare`의 witness 표기는 그대로 유지된다

- 심볼릭 링크로 연결된 Dart 소스를 분석 캐시 입력과 bridge 스캔에 포함
  - analyzer는 파일·디렉터리 링크를 모두 따라가 분석하는데 입력 목록에서는 빠져 있어,
    링크 대상을 수정해도 캐시 키가 그대로여서 낡은 그래프를 돌려주던 문제를 수정한다
  - 같은 이유로 누락되던 링크된 소스의 플랫폼 채널 사실도 추출한다
  - 디렉터리 링크는 이미 따라간 실제 경로를 기록해 순환에서 무한 순회하지 않는다
  - 끊어진 링크는 대상이 없으므로 계속 제외한다

- `dartograph.yaml`의 `entry_points`로 실제 build target을 선언해 `main` 보존 루트를 좁히는 옵션 추가
  - 설정하지 않으면 기존 보수 정책(`lib/`·`bin/`·`example/`의 모든 `main`)을 유지한다
  - 빈 문서와 주석뿐인 문서도 선언한 진입점이 없으므로 같게 보아 기본 정책을 유지하고,
    비어 있지 않은 비-mapping 문서만 거부한다
  - 비어 있거나 절대·루트 밖·비문자열·`lib/`·`bin/`·`example/` 범위 밖·존재하지 않거나 `.dart`가 아닌 경로는 조용히 무시하지 않고 분석 실패로 알린다
  - 존재하지만 `main`이 없는 진입점은 `configured-entry-point-without-main` 한계로 보고한다
  - 보존 루트 의미가 바뀌므로 해석 캐시 identity를 v3로 갱신하고 설정을 캐시 키에 포함한다

## 0.2.0

- 소스별 분석 오류·미해석 호출·조건부 구성의 한계를 finding에 연결
- 단일 색인·도달성 계산을 공유하는 `query --batch`와 라이브러리용 `SymbolQuerySession`
- 두 checkout의 그래프 변화와 사라진 도달 경로를 설명하는 `compare`
- bridge fact에 지원되는 Dart 선언 이름을 추가하고 isthmus 양방향 근거 왕복 검증
- 소스 변형 회귀 평가와 질의 세션 성능 측정 도구

## 0.1.1

- isthmus GRAPH-EXCHANGE v1에 맞춘 UTC 밀리초 생성 시각과 UTF-8 byte 위치
- Flutter services import provenance와 어휘 범위를 따르는 MethodChannel 추출
- cascade와 invokeListMethod/invokeMapMethod, 동적 이름 fact와 미귀속·잘못된 호출 limitation 보강
- EventChannel·BasicMessageChannel, 조건부 import, re-export를 거짓 사실 대신 limitation으로 보고
- Flutter services re-export를 거친 사용은 추측하지 않고 문서화된 누락 방향으로 보존
- explain의 미발견·파일 근거, analyzer 신원·생성 코드·중첩 의존 캐시 판정 보강
- 잘못된 CLI 호출과 Git 실패를 구분하고 옵션 모양의 skill 경로를 거부

## 0.1.0

- Dart analyzer 14.3.0 기반의 결정적 심볼·파일 의존성 그래프
- 근거와 한계를 포함하는 `dead`, `query`, `cycles`, `rules`, `metrics`
- DOT, Mermaid, JSON, text, GitHub Actions, SARIF 출력
- baseline과 Git 변경 범위를 조합하는 `--since`
- 내용·분석기 신원 기반의 손상 허용 영속 사실 캐시
- package barrel 공개 API, 다중 main, override, 생성 코드, 테스트, 플러그인 보존 규칙
- Flutter 플랫폼 채널 교환 사실을 내보내는 `bridges`
- 에이전트용 안전 지침을 출력·설치하는 `skill`
- 종료 코드 `0/1/2/64`, 오탐 코퍼스, 90% 라인 커버리지 게이트
- 대형 프로젝트의 보존 루트 근거를 count·20개 sample·truncated 표시로 제한

dartograph는 MIT 라이선스로 상업적 사용을 포함해 영구 무료이며, 삭제 판정이나
자동 삭제 기능을 제공하지 않는다.

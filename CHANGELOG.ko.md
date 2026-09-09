# Changelog (한국어)

이 변경 이력의 영어 정본은 [CHANGELOG.md](CHANGELOG.md)다. pub.dev에는 영어본이 렌더링된다.

## 0.5.0

- `bridges`에 `--project <shared-root>`와 pub workspace 자동 감지 추가
  (isthmus 모노레포 조인 요청 #38 — GRAPH-EXCHANGE가 공유 루트 선언 방식을
  생산자 옵션에 위임)
  - `--project`는 스캔 범위를 위치 인자 package-root로 유지하면서 문서의
    `project` 필드와 `location.path`를 공유 루트 기준(POSIX realpath, package
    root를 포함하는 기존 디렉터리여야 하며 아니면 usage 64)으로 낸다. pub
    모노레포의 형제 패키지(MethodChannel이 있는 `*_platform_interface`와
    네이티브 쪽 plugin 패키지)가 isthmus의 정확 문자열 일치 조인이 요구하는
    동일한 `project` 문자열을 낼 수 있다 — 문서 손 rewriting은 provenance를
    깨므로 금지
  - pubspec에 `resolution: workspace`를 선언한 패키지는 `--project` 없이 pub
    workspace 루트(`workspace:` 키를 가진 가장 가까운 조상 pubspec — Melos
    정의)를 자동 사용한다. 우선순위: `--project` > workspace 감지 > 스캔
    루트. 감지 실패는 스캔 루트로 폴백하고 `pub-workspace-root-not-found`·
    `pub-workspace-pubspec-unparsed` limitation으로 알려 조인 기준 어긋남이
    조용하지 않다
  - workspace 선언·`--project` 없이는 기존 출력과 byte-for-byte 동일
    (project = 스캔 루트 realpath, 경로 기준 동일) — 기존 bridge 골든 무수정
  - bridges 제어문자 거부 메시지를 "a fact value or source path contains
    control characters"로 정정 — 빈 이름은 throw가 아니라 `empty-bridge-names`
    limitation으로 건너뛰고 소스 경로도 검증하므로 기존 "is empty" 귀속은
    도달 불가/오귀인이었다

- 인덱싱이 출력 byte 동일하게 측정 가능하게 빨라졌다 (감사 P1/P2/P9/P10,
  신규 `tool/benchmark_index.dart` A/B 하네스로 측정 — graph·dead·query·
  retention·test-only 산출물 sha256 전후 동일):
  - element→ID 해석을 관계 수집 패스 단위로 메모화 — 이전엔 식별자 방문마다
    경로 정규화·이름 체인을 재계산했다
  - `CodeGraph.nodes`/`edges` 읽기 뷰를 캐시하고 변경 시에만 무효화 — 매 접근
    전체 재정렬 제거, `_addPublicApiRoots`는 노드 ID 목록을 export 루프 밖으로
    hoist
  - 간선 비교자를 CodeGraph·GraphSnapshot이 공유(결정성 구현 일원화), pubspec을
    인덱싱당 1회 읽기, 선언 소스 경로를 선언당 1회 계산
  - 합성 벤치마크(600파일, 4,923노드/14,726간선, Dart 3.13.3, macos_arm64,
    cold 3회 중 최소): 인덱싱 1456ms → 1053ms (-28%). 머신 의존 수치며 상대
    비교용이고 SLA가 아니다

- 측정된 핫패스 2건 추가 수정(출력 byte 동일, 감사 P4/P8 — 하네스에 rules
  평가 시간·위반 해시 추가):
  - `LayerRuleEvaluator`가 glob RegExp를 패턴별로 캐시 — 노드 × 레이어 × 패턴
    재컴파일 제거(first-match 배치는 매치되지 않는 노드에서 전체 패턴을
    훑는다). 벤치마크: 4,923노드 rules 평가 10.8ms → 3.0ms(-72%), 위반 해시 동일
  - `dead --since`가 finding별이 아니라 고유 source당 1회만 심볼릭 링크를
    해석한다(같은 파일의 finding들이 syscall을 반복했다)

- 도달성·질의 핫 루프가 출력 byte 동일하게 색인화됐다 (감사 P3/P5/P6,
  동일 A/B 하네스·6종 산출물 해시 동일):
  - `ReachabilityResult`에 `isReachable`(Set 조회)·`reachableMemberOf`(dot-접두
    witness 색인 1회 구축, 정렬 순 첫 후보 의미 보존) 추가 — `query` 배치와
    `compare` loss가 질의/loss마다 선형 주사하지 않는다. 합성 벤치마크:
    4,923노드 100질의 배치 10.7ms → 1.7ms (-84%)
  - `analyze`당 reachable ids 이중 정렬 제거(벤치마크 5.7ms → 4.7ms),
    `compareGraphs`의 limitation dedup+sort를 loss 루프 밖으로 hoist

## 0.4.1

- `--since`·`affected`의 Git 변경 매칭이 심볼릭 링크 소스에 대해 양방향이 됐다:
  링크 경로 자체(링크 파일 변경·retarget)와 해석된 실 경로(대상 변경)를 모두
  변경 집합과 비교한다 — 이전에는 해석 경로만 비교해 링크 파일 변경이 조용히
  스코프에서 빠졌다(실측)
- `entry_points`를 선언한 `dartograph.yaml`은 `entry-points: main retention
  roots narrowed to N declared build target(s)` limitation을 보고한다 — PR로 추가된
  설정이 죽은 코드를 클린 저장소와 구별 없이 숨길 수 없다
- SECURITY.md에 심볼릭 링크 유입 채널을 문서화했다: dartograph는 analyzer와
  같이 분석 트리 안의 링크를 따라가므로, 저장소가 링크를 심으면 같은 사용자의
  저장소 밖 파일이 그래프 출력·CI 아티팩트로 흘러갈 수 있다
- 감사 후속 출력 충실성 수정(전부 additive 또는 오정보 제거)
  - `dead --format json`에 `report` 필드(`dead`/`test-only`) 추가 — 저장된
    아티팩트 단독으로도 종료 코드 없이 기계 분류 가능, 4형식 무손실 대칭
  - `dead --format github-actions`가 baseline 억제 발생 시 `::notice ...
    suppressed by baseline` 줄을 낸다(나머지 3형식은 이미 보고 — 0이면 기존
    출력과 byte-for-byte 동일)
  - `graph --format json` 노드가 enum 상수에 `isEnumConstant: true`를 싣는다
    (`line`·`column`과 같은 조건부 필드 규약 — 캐시 문서는 이미 보유했고 공개
    교환 형식도 enum 상수 보존 판정을 재현 가능)
  - SARIF 파일 finding의 1행 1열 `region` 발명을 제거 — SARIF에서 region은
    선택이며 위치 증거 날조는 근거 계약 위반(선언 finding의 실제 region은 유지)
  - 결정성 계약의 두 번째 선언된 예외를 명시: `generated-code-staleness`
    limitation은 mtime 관측이다(git이 mtime을 보존하지 않으므로 fresh clone
    사이에서 presence가 달라질 수 있고, findings·노드·간선은 영향 없음) —
    USAGE·lib/AGENTS.md에 문서화
- 분석 캐시 키가 표준 5 소스 디렉터리뿐 아니라 패키지 루트 아래 모든 `.dart`
  (`.dart_tool`·`.git`·`build` 제외)를 해싱한다 — analyzer는 import 클로저로
  표준 디렉터리 밖 파일(예: `tool/`)도 읽으므로, 키가 이들을 놓치면 그 파일
  변경 후 낡은 해석 결과가 재사용된다(해석 limitation이 사라지는 stale hit
  실측 재현). 숨김 디렉터리(예: `.fvm` 툴체인 링크)는 순회에서 가지치기해 키
  계산이 Flutter SDK 전체 해싱으로 폭주하지 않게 하고, 중첩 패키지 탐지도 표준
  디렉터리 밖 pubspec까지 넓힌다. 루트 밖 상대 경로 import는 문서화된 커버리지
  경계로 남는다. `toolVersion`은 캐시 identity의 일부라 0.4.1로 업그레이드하면
  기존 캐시는 자동으로 무효화된다(1회 재분석)
- CLI 오류 경계를 보강했다 — analyzer·yaml 내부에서 새는 `Error`(TypeError·
  RangeError 등)를 명령 경계에서 분석 실패(종료 2)로 모은다. 내부 경로를 반향하는
  스택트레이스와 미문서화 종료 코드 255가 사라진다. 명령별 catch 비대칭
  (`_runBaseline`의 `on ArgumentError` 부재, compare/query의 ArgumentError 누수)도
  함께 닫힌다
- bridges의 제어문자 정책 거부가 "unable to index the package" 대신 "Bridges
  extraction failed: ..."로 답한다(정확한 귀인 — 이 거부는 인덱싱 실패가
  아니라 추출 정책이다)
- 비-UTF8 `git` 출력(Linux에서 가능한 파일명)을 ChangedFilesException 진단
  ("Changed files could not be computed...")으로 모아 인덱싱 실패로 오귀인하지
  않는다
- 사람·CI 출력 표면 전체의 제어문자·주입 정책을 통일했다 (감사 후속: 개행 포함
  파일명이 Mermaid 라벨을 두 문장으로 절단하고, text 진단줄을 위조하고,
  ESC·bidi 문자가 GitHub Actions 로그로 통과하던 문제)
  - Mermaid: CR·LF를 문서화된 엔티티 코드(`#13;`·`#10;`)로 바꿔 라벨이 항상 한
    물리행에 남는다. 원문의 리터럴 `#10;`은 `#`→`#35;` 선행 치환 덕분에
    라운드트립한다
  - DOT: raw CR도 LF와 같이 이스케이프한다(표시 수준 개행, 문장 구조 보존)
  - text 보고: 경로·ID·근거·한계의 C0·DEL 문자가 가시 이스케이프(`\n`·`\r`·
    `\t`·`\xNN`)로 바뀌어 두 번째 `path:line:col:` 진단줄 위조와 터미널 ANSI
    주입이 차단된다
  - GitHub Actions: 스펙 최소집합(`%`, CR, LF, property의 `:`·`,`)을 넘는
    C0·DEL·C1·U+2028/2029·bidi 제어(U+202A–202E·U+2066–2069)까지 퍼센트
    인코딩을 확장한다 — 기존 `%0D`·`%0A` 관례와 같고 정상 입력은 불변이다
  - SARIF: artifact `uri`를 `Uri(path:)` 대신 경로 세그먼트별 인코딩으로
    만든다. 기존 조립은 `back\slash.dart`를 `back/slash.dart`로 조용히
    손상시키고 리터럴 `%41.dart`를 `A.dart`로 오귀속했다
  - 정책 표는 export 모듈(`lib/src/export/graph_exporter.dart`) 문서로
    정본화했다. 병적 입력에서만 바이트가 바뀌고 정상 경로·ID는 byte-for-byte
    동일하다

## 0.4.0

- `// dartograph:ignore` 인라인 주석 추가 (Periphery comment command 흡수)
  - 선언 위에 오는 줄 주석(doc comment·블록 주석 제외)의 본문이 마커로 **시작**하면
    그 선언의 dead 보고를 억제한다. 산문의 마커 언급은 오발하지 않고
    `// dartograph:ignore — 이유`처럼 뒤에 이유를 적을 수 있다. 같은 줄 꼬리 주석
    (`void foo() {} // dartograph:ignore`)은 다음 선언의 억제로 해석하지 않는다
    (오귀속 방지). 변수·필드는 감싸는 선언의 마커가 적용된다
  - 억제된 선언은 `retentionReason: inlineIgnore` 보존 루트가 되어 `dead --explain`·
    `query`·compare가 그 근거를 답한다. 다른 보존 이유보다 사용자 지시가 먼저다.
    도달성 루트라 억제된 선언이 참조하는 것도 보고에서 함께 사라진다 — 단일
    finding 억제는 baseline을 쓴다. 선언만 억제되고 멤버·파일로 전파되지 않는다
  - 보존 루트 추출 의미가 바뀌어 분석 캐시 identity를 v5로 올린다. 옛 캐시는
    자동으로 재분석된다(직렬화 형식 불변)
- `graph`에 `--level <file|type|symbol>`·`--collapse <n>` 추가
  (cartograph `graph --level`·dependency-cruiser `--collapse` 흡수)
  - `--level file`은 선언을 소속 라이브러리로, `type`은 멤버를 최상위 선언
    컨테이너로 접고, `symbol`(기본)은 그래프를 있는 그대로 그린다. 접힘으로 생긴
    자기 순환은 버려지고 간선은 대표 치환 후 중복 제거된다. 기본값 출력은 도입
    전과 byte-for-byte 동일하다
  - dartograph는 패키지 하나를 분석하므로 cartograph의 module 해상도는 없다
    (패키지로 접으면 단일 정점) — `file`이 가장 거친 해상도다
  - `--collapse <n>`은 파일 수준 그래프를 경로 앞 n 세그먼트로 요약한다
    (`project:lib/src/a.dart` → n=2에서 `project:lib/src`). 폴더 정점은 위치
    필드 없는 집계다. `--level file` 외 결합·값 빠짐·중복·알 수 없는 해상도·
    1 미만·비정수는 usage(64)다
- `graph --format`에 `html` 추가 (cartograph `graph --format html` 흡수)
  - 외부 CDN·스크립트·폰트 참조가 전혀 없는 단일 자기완결 HTML이다. 네트워크가
    막힌 사내망·CI 아티팩트에서도 열리고, 그래프 사실은
    `<script type="application/json">` 페이로드에 실려 인라인 캔버스 힘 기반
    배치·검색·팬·줌으로 렌더링된다
  - 정점 400개를 넘으면 연결이 많은 정점부터 남기고 잘라 낸 사실을 페이지와
    페이로드(`truncatedFrom`)에 적는다. 전체 그래프는 `--format dot`을 쓴다
  - 페이로드의 `<`는 `\u003c`(적법한 JSON 이스케이프)로 바꿔 `<no-library>` 같은
    자체 노드 ID가 script 태그 토큰화를 깨지 않게 한다. limitations는 헤더의
    접히는 목록과 페이로드 양쪽에 실린다
- `affected <git-ref> <package-root>` 명령 추가 (dependency-cruiser `--affected` 흡수)
  - Git 기준점(커밋·브랜치·태그·`HEAD~1` 등) 이후 변경된 파일이 귀속되는 라이브러리를
    씨앗으로 import·export 간선을 역방향으로 건너, 전이적으로 의존하는 라이브러리를
    JSON으로 답한다. part 파일의 변경은 호스트 라이브러리로 귀속된다
  - 각 피영향 라이브러리는 가장 가까운 변경 라이브러리까지의 최단 의존 사슬 `path`와
    `depth` 근거를 싣고, `changed`(씨앗)와 `affected`(종속자)는 겹치지 않는다. 영향
    반경은 라이브러리(파일) 수준 관측이다
  - 분석 대상 라이브러리에 속하지 않는 변경 Dart 파일은
    `changed-dart-files-without-library` 한계로 알린다. Git 실패는 `--since`와 같은
    진단·종료 코드 2, 보고 성공은 영향 개수와 무관하게 종료 코드 0이다
- `dead --report-test-only` 추가 (cartograph parity)
  - 테스트 디렉터리(`test/`·`integration_test/` 등) 보존 루트를 빼고 도달성을 다시
    계산해, 프로덕션 선언인데 테스트에서만 도달되는 것을 고른다. 죽은 코드가 아니라
    "테스트가 유일한 호출자"라는 관측이다
  - `info` 심각도(text `info:`·github-actions `::notice`·sarif `note`·ruleId
    `test-only-declaration`)로 보고하고 finding이 있어도 종료 코드 0이다(빌드를 실패시키지
    않는다). 테스트 디렉터리 내부 선언과 `@visibleForTesting` 프로덕션 선언은
    보수적으로 제외한다
  - 단일 대상 질의인 `--explain`, dead finding을 억제하는 `--baseline`과는 결합하지
    않으며(usage 64) `--since`·`--format`은 허용한다
- `cycles --explain <symbol-id>`·`rules --explain <symbol-id>` 추가 (cartograph 근거 parity)
  - `cycles --explain`은 한 정점이 강결합 요소로 참여하는 순환과 각각의 `breakCandidate`
    (끊을 후보 간선)를 JSON으로 낸다. 한 정점은 최대 하나의 강결합 요소에 속하므로 0·1개다
  - `rules --explain`은 정점이 배치된 레이어, 배치를 결정한 `matchedPattern`·
    `matchedCandidate`, 그 레이어에서 출발하는 `rules`를 JSON으로 낸다. 매치된 레이어가
    없으면 해당 필드들이 null·빈 목록이다(`--config`는 계속 필요)
  - 두 `--explain` 모두 단일 정점 질의라 `--strict`와 결합하지 않으며(usage 64), 그래프에
    없는 ID는 `known: false`와 종료 코드 64, 알려진 ID는 참여와 무관하게 종료 코드 0이다
- `query`에 `--depth <n>`·`--limit <n>` 추가 (cartograph SymbolQueryDocument parity)
  - `--depth`(기본 1)는 사용 관계(`usedBy`·`dependsOn`)를 n단계까지 BFS로 따라가고, 각
    이웃의 `depth` 필드가 출발 심볼에서 몇 걸음인지 나타낸다. 한 이웃에 닿는 여러 간선
    종류를 `edges`에 모두 싣고, 여러 경로로 닿는 이웃은 최단 깊이 한 번만 보고한다
  - `--limit`은 방향별 이웃 수를 제한하며, 생략하면 해당 방향 `truncated`가 `true`가 되고
    생략된 이웃은 더 확장하지 않는다. 포함 관계(`members`·`declaredIn`)는 항상 한 단계다
  - 기본값(depth 1, limit 없음)에서 기존 출력을 보존한다. 단, **좁은 파괴적 변경**:
    재귀처럼 자기 자신으로 향하는 사용 간선은 cartograph와 같이 자기 자신의 이웃에서
    제외된다(옛 1-hop 순회는 포함했다). 1 미만·비정수·값 빠짐·중복 플래그는
    usage(64)다. `--batch`·`--baseline`과 함께 쓸 수 있다
- 사용 중인 `operator` 선언이 dead로 보고되던 오탐 수정
  - 연산자 구문(`a + b`·`a[i]`·`-a`·`a++`·`a += b`)은 식별자가 아닌 토큰을 거쳐
    해석되므로 사용 간선이 만들어지지 않았다. 클래스·extension type의 연산자 선언이
    소비 중에도 미도달로 잘못 보고됐다
  - 이제 해석된 연산자를 `call` 간선으로 기록한다. `a[i] = v` 쓰기는 기존 reference
    경로를 유지하고, 복합 대입·증감(`m[i] += v`·`m[i]++`)의 읽기·쓰기가 거치는
    `[]`·`[]=`도 연산자 호출로 기록한다. 내장 연산자(dart:core)는 노드가 없어
    간선이 생기지 않고, 미사용 연산자와 쓰기만 소비된 읽기 연산자는 계속
    보고된다(양방향 코퍼스 회귀)
  - 추출 의미가 바뀌어 분석 캐시 identity를 v4로 올린다. 옛 캐시는 자동으로
    재분석된다(직렬화 형식은 불변)
- 입력 오류 메시지를 원인별로 구분해 원인을 반대로 가리키지 않게 수정
  - baseline 파일이 없으면 "unable to index the package" 대신 "Baseline is invalid:
    create it with dartograph baseline --write"를 낸다
  - `rules --config` 파일이 없거나 잘못되면 "Analysis failed: unable to read the rules
    configuration."을 낸다(인덱싱 실패와 구분, `Analysis failed:` 접두는 유지)
  - `baseline --write`의 쓰기 실패(목적지 생성·권한)는 "unable to index the package" 대신
    "Baseline write failed: unable to write the baseline file."을 낸다(인덱싱은 이미 성공)
- 퍼센트 인코딩된 파일명의 dead file finding이 파일 수준 한계를 유지
  - `Uri.path`가 유지하는 `%20` 등을 디코딩해 analyzer가 실제 경로로 만든 source 한계와
    매치되게 한다. 이전에 그 파일의 한계가 finding에서 조용히 사라졌다
- Mermaid 출력이 자체 노드 ID의 `<`·`>`·`&`·`"`·`\`·`#`를 HTML 엔티티 코드로 escape
  - DOT용 백슬래시 escape를 재사용해 `<no-library>`·`<unnamed-extension@...>`를 Mermaid가
    HTML 태그로 오해하던 문제를 고친다
  - 따옴표는 인용 문자열을 중간에 끊어 라벨 구조를 깨므로 Mermaid가 문서화한 엔티티 코드
    (`#quot;`·역슬래시 `#92;`·`#` 자체 `#35;`)로 바꾼다
- `--help`가 `--explain`이 `--format json`을 요구하고 `--baseline`·`--since`와 결합하지
  않음을 안내한다
- 에이전트용 `skill` 출력에 `affected` 항목과 `inlineIgnore` 근거 문구를 추가한다
  (신규 기능과 함께 갱신)

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

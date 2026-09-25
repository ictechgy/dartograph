# Changelog (한국어)

이 변경 이력의 영어 정본은 [CHANGELOG.md](CHANGELOG.md)다. pub.dev에는 영어본이 렌더링된다.

## Unreleased

- 새 `schema --format json [--project <shared-root>] <package-root>` 명령이 isthmus persistence `relation-use` 사실(bridge-facts v1, `target: "persistence"`)을 낸다. sqflite·sqlite3·postgres·drift(테이블·custom 쿼리·`.drift` 파일)·floor와 대문자 SQL 문자열 리터럴을 읽어 isthmus가 Dart 코드와 schemagraph SQL 카탈로그를 조인하게 한다. SQL 판독기는 kartograph·cartograph 공용 추출기의 포트다. 비리터럴 SQL은 동적 사실로, 비관계 저장소·지원 밖 SQL 패키지는 한계로 남긴다. 기존 명령은 바뀌지 않았다.
- 생성자(기본·named·factory)를 소속 클래스로 모델링한다는 사실을 문서화했다. 생성자 ID는 그래프 정점이 아니고, 쓰이지 않는 생성자는 `dead`가 보고하지 않으며, 생성자 변경의 `impact`는 클래스 단위다. 분석 동작은 바뀌지 않았다.

## 0.15.2

- callable 객체 호출(`validator('x')`·`holder.validator('y')`)이 암묵 `call` 메서드로 호출 간선을 남기고, 암묵 `call` tear-off는 참조 간선을 남긴다. 이전에는 이런 `call`이 dead로 보고되고 `impact`에서 빠졌다. 분석 캐시 identity를 올려 이전 결과를 폐기한다.

## 0.15.1

- 사용자가 선택한 Scout 새 마스코트를 한·영 README와 VS Code 확장 아이콘에 적용했다.
- 실제 CLI 데모와 확대된 도구 사용률 실험 결과를 패키지 문서에 포함하고 실험의 채점 한계를 유지했다.
- `coden.kr` verified publisher 설정 완료를 기록하고 그래프 교환 가이드의 추출 시각과 선택적 소스 수정 시각을 구분했다.
- 분석 동작과 CLI 인자는 바뀌지 않았다.

## 0.15.0

- `setup --target claude|cursor|codex|opencode`와 `setup --uninstall`이 기존 설정을 보존하면서 에이전트 연동을 설치·제거한다. Claude setup은 도구 발견용 저장소 라우팅 블록도 관리한다.
- `query --with-source [--source-context N]`가 선언의 소스 줄을 포함한다. `cycles`·`rules`·`metrics`·`affected`·`compare`는 text/JSON/SARIF를 지원하고 query는 JSON 전용을 유지한다.
- `impact --format test-list`가 선택 실행용 테스트 경로를 낸다. 저장소에 합성 GitHub Action과 SARIF 설정 가이드를 추가했다.
- bridge-facts 교환 가이드를 공개하고 RN 전역 이벤트·외부 보존 계약을 자매 도구와 맞췄다. dartograph에 RN 소스 추출을 추가한 것은 아니다.
- 에이전트 벤치마크 하네스와 도구 사용률 실험을 기록했다. 사용률은 기록된 모델·과제의 관찰이며 일반적인 코딩 성능 향상 주장이 아니다.

- 옵트인 `--workspace`가 pub 워크스페이스를 집계한다: 루트
  `pubspec.yaml`이 `workspace:` 멤버를 선언하면 인덱스 소비 명령
  (`graph`, `query`, `dead`, `deps`, `dup`, `cycles`, `rules`,
  `metrics`, `impact`, `baseline`, `runtime`)이 루트와 모든 멤버
  패키지를 함께 분석하고, 멤버의 `lib/`·`test/`·`bin/`·`example/`
  소스·barrel·plugin·`build.yaml` 진입점을 패키지별로 보존한다.
  `deps --workspace`는 각 패키지를 자기 pubspec 기준으로 감사하고
  발견에 `manifest` 필드를 붙인다(text·Markdown 열, GitHub Actions
  `file=`, SARIF artifact URI가 소유 pubspec을 가리킨다). 멤버의
  `dartograph.yaml`은 무시하고 보고한다. 읽을 수 없거나 symlink인 멤버
  경로는 건너뛰고 보고하며, 루트 pubspec이 `workspace:` 멤버를 선언하지
  않거나 선언된 멤버가 전부 건너뛰어지면 분석 실패(exit 2)다. 집계
  결과는 단일 패키지 스캔과 다른 캐시 키를 쓴다. MCP 도구는 같은
  `workspace` 불리언을 받는다.
- 새 읽기 전용 MCP 도구 `dartograph_explore`는 단일 진입점이다:
  `packageRoot`에 질문 형태 하나를 붙이면 내부적으로 라우팅한다 —
  `symbol`/`batch`는 `dependency_query`(`withSource` 기본 켜짐,
  `sourceContext` 3), `impactSymbol`/`since`/`changed`는 `impact_query`,
  `command`는 `verify_run`, `command: "runtime"`은 `runtime_query`로.
  응답 첫 줄이 라우팅된 경로를 밝히고, 라우팅된 형태에 해당하지 않는
  인자는 조용히 무시하지 않고 거부하며, 형태가 없는 호출에는 라우팅
  메뉴를 돌려준다. 서버 환경 변수 `DARTOGRAPH_MCP_LEGACY_TOOLS`를
  `0` 또는 `false`로 두면 `tools/list`가 `dartograph_explore`만 광고한다;
  좁은 도구들은 계속 호출할 수 있다.

## 0.14.0

- MCP 서버가 세션별 `dartograph-mcp-cache.*` 임시 디렉터리에
  `packageRoot`별 하위 디렉터리를 둔 증분 캐시를 쓴다 — 한 세션의 반복
  질의가 파일 단위 사실 캐시를 재사용한다. 캐시 생성·쓰기 실패는 결과
  동등한 전체 해석으로 폴백하고 진단은 stderr에만 남기며(경로 미노출)
  세션 종료 시 디렉터리를 지운다 (#117).
- 읽기 전용 MCP 도구 `runtime_query` 추가 — `runtime --no-verify
  --format json` 고정 인자의 정적 탐지 조회다. `packageRoot`와 선택
  `limit`만 받고 실행·환경 주입·record·필터 인자는 거부한다 (#117).
- `runtime --kinds <csv>`는 보고하는 사실 카테고리(`env`,`dynamicLoad`,
  `config`,`asset`,`external`)를, `runtime --statuses <csv>`는 판정
  절(`present`,`defaulted`,`missing`,`unverified`)을 좁힌다. 필터는
  보고 목록만 좁히고 위험도·limitations·종료 코드는 필터 전 전체 분석
  기준을 유지하며 `--limit`은 필터된 목록에 적용된다. `--statuses`는
  `--no-verify`와 결합하지 않고 알 수 없는·빈·중복 값은 usage 오류다
  (#117).
- 런타임 보고서에 `unverifiedReasonCounts` 추가 — 미판정 사실을 사유
  접두사별로 사전순 집계(접두사 없는 사유는 `unspecified`)해
  JSON·text·markdown·SARIF 모두에 직렬화한다 (#117).

## 0.13.0

- `runtime --execute`가 `dart install`/`dart compile exe` 배포본에서 실행
  파일명, `DART_SDK`, `PATH` 순으로 Dart SDK를 해석하고 자기 재실행 대신
  사유를 보고한다. `DynamicLibrary.open`의 맨 이름은 파일 존재 검사 대신
  미판정으로 남기고, `external` 네트워크 탐지는 `Uri.parse`나 알려진
  네트워크 API 인자 자리의 http(s) 리터럴만 보고한다 (#108).
- `dup` 발견 정렬이 전순서가 됐다 — 같은 길이의 3-way 중복은 둘째 인스턴스
  까지 비교한다. `dead`의 `redundantPublic`이 구조적으로만 보존된 선언
  (sealed 서브타입·도달 멤버의 컨테이너)을 더는 지적하지 않는다 — 내부
  전용이 아니라 미관측이다 (#110).
- 패키지 루트 밖을 가리키는 심링크는 analyzer처럼 계속 따라가되
  `symlink-escape:` limitation으로 드러낸다 — 분석·`bridges`·`runtime`
  출력 모두에 (#111).
- MCP stdio 프레이밍이 JSON-RPC 한 줄을 1MiB로 제한하고(초과 메시지는
  `Invalid JSON` 응답, 연결은 유지), 모든 도구의 `packageRoot`가 서버 작업
  디렉터리 안의 실제 디렉터리로 해석돼야 한다 — 경계 밖·`..`·심링크 우회는
  인자 오류로 거부한다. 생성된 Claude Code 훅은 python3/jq와 실패 시 닫히는
  sed 폴백으로 도구 입력을 해석한다 (#112).
- 출력 이스케이프를 `ReportEscapes`로 통합했다. `bridges`가
  `package:flutter/services.dart`의 provenance를
  `.dart_tool/package_config.json`으로 검증하고 못 하면
  `flutter-services-provenance-unverified`를 기록한다. `--execute`
  타임아웃은 직계 프로세스만 죽이므로 `execute-process-scope`를 기록한다
  (#114).
- 성능: 중복 탐지가 롤링 윈도 해시를 쓰고, sealed 서브타입 전파가 미리 만든
  상속 인덱스를 쓰며, `--since`·impact 매칭의 canonical 경로 해석을
  병렬화하고, pub cache 아래 hosted/git 의존은 `lib/` 전체를 캐시 지문에
  넣지 않는다(path 의존은 계속 넣는다). `history`가 원장을 스트리밍으로
  읽는다 (#113).

## 0.12.0

- `dartograph dup` 추가 — `--min-tokens`와 전 보고 형식을 지원하는 토큰
  shingle 중복 블록 탐지. 발견은 검토 후보이지 병합 지시가 아니다.
- `metrics`에 함수 수준 순환 복잡도와 hot-spots 랭킹을 추가하고
  `thresholds.complexity`로 `--strict` 게이트한다.
- `dead`/`deps`/`dup`에 발견 종류 필터 `--kinds` 추가.
- `dartograph.yaml`에 `include`/`exclude` 경로 glob, `retained_names`/
  `retained_files` 보존 루트, `thresholds` 추가.
- CODEOWNERS 매칭이 전체 문법(`!` 부정·문자 클래스·`\` 이스케이프)을 지원한다.
- `dartograph setup` 추가 — Claude Code PostToolUse 훅을 설치하고 MCP 서버
  설정을 기존 키를 보존하며 병합한다.
- MCP `verify_run`이 `dup`/`--kinds`를 지원하고 `duplication-review`
  프롬프트가 추가됐다.
- VS Code 확장 `ictechgy.dartograph`가 Marketplace에 게시됐다 — CLI JSON
  보고가 Problems 진단이 되고 `runOnSave`·현재 파일 impact 검사를 제공한다.
- `editors/analysis_plugin/`의 `dartograph_analysis_plugin`(pub.dev 게시)은
  IDE와 `dart analyze`에서 `dead`/`dup` 발견을 `dartograph_dead_code`/
  `dartograph_duplicate_block` 진단으로 내고 `// dartograph:ignore`
  quick fix를 제공한다.
- `bridges --events` 추가. EventChannel `receiveBroadcastStream` 수신 호출을
  bridge-facts v2(`transport: event-channel`, `kind: stream-listen`)로 내는
  opt-in producer 경로다. 수신자가 `EventChannel` 생성으로 입증된 호출만 사실이
  되고, 임의의 `.listen()`이나 미입증 수신자는 `unresolved-stream-listens`로
  센다. 동적 채널 이름은 `dynamic-event-channel-names` 아래 literal
  `channelPrefix`를 보존한다. `--messages`와 `--events`는 서로 다른 transport
  문서라 함께 쓸 수 없고, 기본 `bridges` 출력은 v1 MethodChannel 사실 그대로다.

## 0.11.0

- `dartograph deps` 추가. 선언된 `dependencies`/`dev_dependencies`/`dependency_overrides`와
  관측된 `package:` import·export를 대조하는 pubspec 위생 감사다. 네 종류의 발견
  (`unused-dependency`·`unused-dev-dependency`·`dev-dependency-in-lib`·
  `undeclared-dependency`)을 다섯 형식(text·json·markdown·github-actions·sarif)으로
  보고하고 finding이 있으면 종료 코드 1을 반환한다. 도구 계약 의존성(`executables`·
  `build.yaml` builders·`analysis_options` includes/plugins)은 package_config 근거로
  사용분으로 세고, 런타임/생성/asset 참조는 limitation으로 남는다. 발견은 검토
  목록이지 삭제 지시가 아니다.
- `dead --closed-app`과 `baseline --write --closed-app` 추가. 독립 실행 앱(Flutter
  앱·CLI 실행 파일)에서 공개 API 보존 루트를 제거해 `main`에서 도달하지 못하는 공개
  선언이 `lib/<package>.dart`의 export 대상이어도 보고되게 한다. 보고서는
  `closed-app-analysis` limitation으로 모드를 명시하고 `--report-redundant-public`과의
  결합은 usage 오류(64)다. 게시 라이브러리에는 쓰지 않는다.
- MCP 서버가 `tools/*`와 함께 `resources/list`·`resources/read`,
  `prompts/list`·`prompts/get`을 처리하고 `initialize` capabilities에 선언한다.
  정적 리소스 세 종류(`dartograph://usage`·`dartograph://skill`·`dartograph://config`
  — CLI 도움말·생성 스킬·설정 템플릿과 같은 본문)와 프롬프트 세 개
  (`impact-precheck`·`dead-code-review`·`dependency-audit`)를 노출하고 알 수 없는
  리소스 URI는 `-32002`로 답한다. `verify_run`은 `deps` 명령과 `closedApp` 플래그를
  받되 `dead`가 아닌 명령에 주면 인자 오류로 거부해 조용히 무시되는 플래그를 막는다.
- `dead`가 sealed 계층을 구제한다. 도달 가능한 sealed 선언은 직접·전이적 서브타입을
  enum 상수와 같은 방식으로 살려 두며, 새 `GraphNode.isSealed` 표시를 읽는다.
- index가 패키지 manifest 사실(선언된 dependencies·dev_dependencies·
  dependency_overrides·패키지별 `package:` 지시문 import)을 추가로 수집하고,
  `build.yaml` builder가 요구하는 팩토리 함수를 `buildRunner` 루트로,
  `@JS`/`@staticInterop`/FFI 계열 annotation 대상을 `externalBinding` 루트로
  보존한다. 사실 캐시 스키마는 v4, index identity는 v7로 갱신했다.
- analyzer 14의 AST 변화로 생긴 회귀를 고쳤다 — 멤버와 선언 사이에 `ClassBody`
  노드가 끼어 ancestor 순회가 멈춰 기존 보존 근거를 잃던 문제. 이제
  `Declaration`이 아닌 노드를 건너뛰고 `CompilationUnit`까지 올라간다.
- index가 `include:` 목록·`@anonymous` 지시문·해석되지 않는 `build.yaml` import를
  인식하게 고쳤고, project-scheme dead 파일이 난독화되지 않은 소스로 보고된다.
- CLI가 `dead`의 값 있는 옵션(`--explain`·`--format`·`--baseline`·`--since`·
  `--codeowners`)이 중복 지정되면 조용한 last-win 대신 usage 오류로 거부하고, 읽을 수
  없는 `--changed` 입력을 분석 실패가 아니라 usage 오류로 분류한다.
- 리포터가 C1·bidi 제어 문자를 이스케이프하고 markdown code span을 안전하게
  fence한다. 이스케이프 정책은 `report_escapes.dart`로 공유한다.
- MCP가 notification 형태의 request 메시지를 무시하고 문자열로 온 `closedApp`
  값을 인식한다.

## 0.10.0

- 색인 명령 11개(`graph`·`dead`·`query`·`compare`·`affected`·`impact`·`baseline`·
  `cycles`·`rules`·`metrics`·`dead --explain`)에 `--incremental <dir>` 추가. 파일 내용
  해시와 그 파일의 해석 입력을 섞은 키로 파일별 사실을 캐시하고, 다음 실행에서 바뀐
  파일과 그 파일을 (전이적으로) import·export하는 라이브러리만 다시 해석한다. 산출물은
  전체 해석과 byte 동일하다(`tool/benchmark_index.dart`가 세 조건에서 7종 sha256을
  대조한다). 캐시는 최적화지 계약이 아니다 — 캐시가 없거나 손상됐거나 스키마가
  다르거나 쓸 수 없으면 전체 해석으로 폴백하고 쓰기 실패만 limitation으로 남긴다.
  프로젝트마다 다른 디렉터리를 쓴다. 합성 600파일 실측: warm(변경 없음) 7.5배,
  leaf(잎 파일 변경) 1.9배, imported(널리 import되는 파일 변경) 약 1.0배 — 허브 편집은
  역방향 폐쇄가 거의 전체라 낙관 없이 그대로 기록한다

- 검증 원장 추가. 분석 명령의 `--record <dir>`는 실행 하나를 `<dir>/ledger.jsonl`에 한
  줄(JSON)로 덧붙인다: 도구 버전·UTC 시각·명령·종료 코드·관측한 Git `HEAD`(계산하지
  못하면 null)·입력 플래그·보고한 문제 식별자. 파일은 append-only라 기존 줄을 다시 쓰지
  않는다. `--env`·`--dart-define`은 값이 비밀일 수 있어 키만 남긴다. 쓰기가 중단돼
  마지막 줄이 잘리면 읽기가 건너뛰고 `ledger-skipped-lines` limitation으로 보고하며,
  다음 append는 잘린 줄을 개행으로 닫고 새 줄을 쓴다. `dartograph history --ledger <dir>
  [--commit <sha>] [--format text|json]`가 되읽는다. 원장을 쓰지 못해도 분석 결과와 종료
  코드는 그대로이고 진단만 stderr로 간다

- `dead --format markdown` 추가 — 다른 형식과 같은 제어문자 정책의 표 리포트이며,
  finding별·전역 limitation을 함께 낸다

- `dead --format codeowners --codeowners <file>` 추가 — finding 소스 경로의 소유자별로
  묶는다. CODEOWNERS 형식의 문서화된 부분집합을 구현한다: 마지막 일치 규칙이 이기고
  `*`·`**`·`?`를 지원하며, `/`가 든 패턴은 프로젝트 루트에 고정되고, 끝의 `/`는
  디렉터리 규칙, 소유자가 없는 규칙은 앞선 규칙으로 되돌아가지 않고 소유권을 비운다.
  규칙에 없는 경로는 `(unowned)`로 묶인다

- CI 문서: `impact-precheck` 워크플로 예시가 PR에서 돌아 `impact --format markdown`
  리포트를 PR 코멘트로 달고(제자리 갱신), 증분 사실 캐시와 검증 원장을 쓰며, SARIF를
  올리고 high 위험에서 게이트한다. MCP 문서에 `tools/list` 입력 스키마, JSON-RPC 오류
  코드 표, 재현 요청/응답 예시를 추가했다

## 0.9.0

- 수정 **전에** 영향을 묻는 `dartograph impact` 명령 추가. 씨앗은 정확히 하나를 준다:
  `--since <git-ref>`(Git 변경 파일, `affected`와 같은 전체 이력 요구·심볼릭 링크 양방향
  매칭), `--changed <changes.json>`(프로젝트 상대 경로 1–1000개, 1 MiB 이하), 또는
  `--symbol <symbol-id>`. 보고서는 변경된 라이브러리·심볼, 그들을 전이적으로 사용하는
  심볼(`call`·`reference`·`inheritance`·`implements`·`mixin`·`override`·`import`·
  `export`)과 최단 사용 경로·깊이, 변경 선언으로 들어오는 호출 지점(파일·줄·열), 변경
  집합에 의존하는 테스트 라이브러리, 요인별 위험도(0–100, `low`/`medium`/`high`)를 낸다
  (`inbound-references`·`impact-depth`·`impact-breadth`·`public-api-surface`·
  `test-coverage`·`cycle-participation`). `coverage` 블록은 사전 점검이 놓치지 않게 하는
  범위를 밝힌다 — 직접 변경된 심볼 수, 전이 영향 수, 관련 테스트 수, 그리고 변경 파일만
  확인했을 때 보이지 않는 심볼 목록 `missedWithoutPrecheck`다. 출력은 `text`·`json`·
  `markdown`·`github-actions`·`sarif`이고, `--depth`는 전이 탐색을, `--limit`은 보고
  항목만 제한한다(개수·위험도·종료 코드는 바뀌지 않고 생략한 수는 목록별로 표시된다).
  `--fail-on <none|low|medium|high>`은 전체 위험도가 임계 이상이면 종료 코드 1로 만든다
  (기본 `none`은 항상 0). `--symbol` 씨앗이 그래프에 없으면 `known: false`와 종료 코드
  64로 구분하며, 나열되지 않은 선언이 영향을 받지 않았다고 주장하지 않는다

- `dartograph mcp` 명령 추가 — stdio로 Model Context Protocol 서버를 띄운다(JSON-RPC
  2.0, protocolVersion `2024-11-05`). `initialize`·`ping`·`tools/list`·`tools/call`과
  `notifications/*`를 처리하고, 알 수 없는 메서드는 `-32601`, 잘못된 JSON은 `-32700`,
  잘못된 파라미터는 `-32602`로 답하면서 서버는 계속 동작한다. 도구는 셋이다:
  `impact_query`(`impact --format json` 문서, `since`/`changed`/`symbol` 중 정확히 하나),
  `dependency_query`(`query`/`query --batch` 문서, `symbol`/`batch` 중 정확히 하나),
  `verify_run`(`dead`·`cycles`·`rules`·`metrics`의 원시 출력과 종료 코드, 분석 실패·사용
  오류는 `isError: true`). 모든 도구는 CLI와 **완전히 같은** `runDartograph` 실행 경로를
  재사용하므로 결과 스키마와 종료 코드가 `dartograph` 자체와 어긋나지 않는다. stdout에는
  JSON-RPC만 쓰고 진단은 stderr로 보내며, 도구는 읽기 전용이다 — `changed`·`batch` 배열을
  위해 쓴 임시 파일은 호출이 끝나면 지운다

- 정적 import 그래프에 잡히지 않는 입력을 찾아 환경에 대해 판정하는 `dartograph runtime`
  명령 추가. 탐지 사실은 다섯 카테고리다: `env`(환경변수·`--dart-define`),
  `dynamicLoad`(`Isolate.spawnUri`, `Process.run`/`start`, `DynamicLibrary.open`,
  `dart:mirrors`, `Function.apply`), `config`(설정 파일·경로), `asset`(`pubspec.yaml`의
  `flutter.assets` 선언과 `rootBundle`·`Image.asset`·`AssetImage`), `external`(http(s)
  목적지). 각 사실은 주어진 환경에서 `present`·`defaulted`·`missing`으로 판정되고, 정적으로
  확정할 수 없거나 프로브할 수 없으면 사유와 함께 `unverified`로 남는다. 미충족·미판정·
  외부 자원 수는 위험도(0–100, `low`/`medium`/`high`)로 합산된다. `--env KEY=VALUE`·
  `--dart-define KEY=VALUE`는 반복 지정할 수 있고 같은 키는 마지막 값이 이기며 값 자체는
  절대 출력되지 않는다. 둘 중 하나라도 주면 판정이 hermetic해져 프로세스 환경을 무시하고
  `environment-source` limitation으로 남기며, 두 채널은 서로를 충족하지 않는다.
  판정은 기본으로 수행하고 `--verify`로 명시할 수 있으며, `--no-verify`는 판정 없이
  탐지만 한다(위험도 없음). `--execute <dart-entrypoint>`는 패키지 루트에서 PATH의
  Dart SDK로 `dart run <entrypoint>`를 실행하고 `--env` 값을 상속 환경 위에 덮어쓴 뒤
  종료 코드와 stderr 요약을 실행 증거로 남긴다. 실행 실패는 보고를 대체하지 않고
  `execution-failed` 위험 요인이 된다. `--format`은 `text`·`json`·`markdown`·
  `github-actions`·`sarif`, `--limit`은 보고 항목만 제한하고,
  `--fail-on <none|low|medium|high>`는 임계 이상에서 종료 코드 1로 만든다.

- native executable의 `runtime --execute`가 자기 자신 대신 PATH의 Dart SDK를 실행하도록
  수정했다. 설치 계약은 entrypoint가 실제 실행 근거 파일을 만드는지도 확인한다.
- 런타임 실행 제한 시간을 프로세스 종료와 출력 수집에 함께 적용한다. 후손이 상속한
  출력 파이프를 계속 보유해도 제한 시간에 수집을 중단한다.

- local path dependency source를 선택적으로 포함하는 `source_packages` 설정을
  추가했다. package root는 프로젝트 상대 경로의 canonical non-symlink 디렉터리이며
  `pubspec.yaml`과 `lib/`를 가져야 한다. generated/cache·중복 root는 fail-closed로
  거부하고, 기본 분석 범위는 유지한다. 기존 `package:` identity를 보존하며 설정과
  package 내용은 분석 캐시를 무효화한다.

- Flutter `BasicMessageChannel.send` 호출을 관측하는 개발 소스 전용
  `bridges --messages --format json` producer를 추가했다. `transport:
  "basic-message-channel"`과 `kind: "message-send"`를 담은 bridge-facts v2를
  내보내며, 채널 생성과 MethodChannel 메서드 fact를 서로 섞지 않는다. 동적 이름은
  원래 소스 표현식을 유지하고, `channelPrefix`는 AST가 문자열 interpolation의
  decoded 비어 있지 않은 선행 literal을 증명할 때만 낸다. prefix는 완전한 runtime
  주소나 instance identity가 아니라 후보 근거이며, 이 producer는 `0.9.0`에 새로
  추가되었다.

## 0.8.0

- 공개 라이브러리 API를 보여주는 실행 가능한 `example/main.dart` 추가 — `CodeGraph`를
  직접 구성하고 스냅샷한 뒤 `SymbolQuerySession`으로 미도달 선언을 질의하고 `toJson`으로
  직렬화하는 흐름이다

- 검증된 `analyzer` 의존성 범위를 `>=14.3.0 <15.0.0`으로 넓혔다(14.4.x를
  `doc/DECISION-analyzer.md` 절차대로 재검증 — 전체 테스트 스위트가 14.4.0에서
  컴파일·통과). 캐시 키는 이미 해석된 패키지 설정을 반영하므로 analyzer 업그레이드 시
  캐시가 자동 무효화된다

- `dartograph init [--force] [<package-root>]` 명령 추가 — 프로젝트 루트에 주석 달린
  `dartograph.yaml` 설정 템플릿을 생성한다(cartograph `init` 패리티). 템플릿은 구현된
  스키마(`entry_points`)만 광고한다. 기존 파일이 있으면 exit 64로 중단하고 `--force`로
  덮어쓴다. 쓰기는 원자적 교체다 — 대상 자리의 심볼릭 링크는 링크 자체를 교체하며 따라가지
  않는다

- 실행 가능한 CLI 진단과 `--help` 계약 문서를 보강했다: `skill --install`의 성공·충돌
  메시지가 실제 설치 경로(`<dir>/dartograph/SKILL.md`)를 알려준다. `rules` 설정 실패는
  읽기 실패(사용자가 준 `--config` 값을 표시)와 형식 오류(파서 상세, 경로 없음)로 나뉜다.
  알 수 없는 리포트 포맷·그래프 레벨·그래프 포맷 한줄 오류가 유효값을 함께 알려준다.
  `init`은 대상 디렉터리에 `pubspec.yaml`이 없으면 stderr로 경고한다(종료 코드는 0 유지).
  `--help`는 skill 설치 경로와 링크-자체-교체 정책, 종료 코드 계약(미도달 대상의
  `dead --explain`은 1, 그래프에 없는 query/--explain 대상은 64)을 문서화한다

- 보안 경화: `skill --install`은 더 이상 대상 자리의 심볼릭 링크를 관통해 쓰지 않는다 —
  기존에는 `File.writeAsString`이 링크를 따라가 신뢰할 수 없는 체크아웃 밖 파일을 덮어쓸 수
  있었다(링크가 매달려 있으면 `--force`도 필요 없었다). init·skill·baseline 쓰기는 임측하기
  어려운 임시 이름(PID+암호학적으로 안전한 생성기의 접미사)과 배타적 생성을 갖춘 하나의
  원자적 쓰기 경계를 공유한다 — 임시 경로에 미리 심어둔 내용물은 절단·관통되지 않고
  fail-closed로 실패한다. **경미한 파괴적 변경**: `<dir>/dartograph/SKILL.md`의 매달린
  링크는 이제 `init`과 같이 `--force`를 요구한다 — `--force` 없이는 그 자리의 기존 파일·
  링크를 exit 64로 거부한다

- **경미한 파괴적 변경**: 저장소가 제공하는 YAML 설정 파일(`dartograph.yaml`,
  `pubspec.yaml`, `rules --config`에 주는 layers.yaml)이 1 MiB를 넘으면 파서에 넘기지
  않고 경로 없는 정적 오류로 거절한다(fail-closed 자원 상한. 실제 설정은 이보다 몇 자릿수
  작다). 각 읽기 지점은 기존 실패 계약을 유지한다(분석 종료 코드 2, 또는 workspace 감지
  limitation 폴백)

- 성능: 핫 루프 안에서 정규식을 다시 컴파일하지 않는다 — `dead --report-redundant-public`의
  연산자 이름 패턴, fact 캐시 키 패턴, bridge fact 제어문자 패턴, 생성 파일 sibling 접미
  패턴을 한 번만 만든다. dead 선언·dead 파일·redundant-public 발견 루프의 source별
  limitation 필터링을 메모한다. 새 상한·거절이 발동하지 않는 입력에서 분석 출력은 0.7.0과
  byte-for-byte 동일하다(산출물 해시 동일성으로 검증)

## 0.7.0

- `graph` 명령에 프라이버시를 보호하는 익명화 그래프 내보내기 포맷인 `--format anon` 추가
  (dependency-cruiser `anon` 리포터 패리티). 그래프 구조, 확장자, Dart 표준 관용 어휘
  화이트리스트를 보존하면서 패키지 상대 경로와 파일명을 결정적·단사 식별자(`s0`, `s1`, …)로
  치환한다. 분석 제한사항(limitations) 문구는 전체 키 교대 패턴을 1회 통과시켜 이중 치환
  누출을 방지한다

- `dead` 명령에 선언된 라이브러리 외부에서 결코 참조되지 않는 공개 선언을 감지하는
  `--report-redundant-public` 옵션 추가 (Periphery redundant public accessibility 패리티).
  `--report-test-only`와 동일한 info 계약(진단 항목이 있어도 종료 코드 0)을 따른다.
  `--explain`·`--baseline`·`--report-test-only`와는 결합하지 않으며(usage 64),
  `--since`와 기계 가독 포맷은 허용된다. 보존 루트, enum 상수, override 구현체,
  연산자, 비공개 컨테이너 멤버는 보수적으로 제외한다

- `metrics` JSON 출력의 각 항목에 아키텍처 영역을 나타내는 `zone` 필드 추가
  (cartograph `MetricsZone` 패리티). 각 컴포넌트 메트릭에 `zone` 필드(`main-sequence`,
  `zone-of-pain`, `zone-of-uselessness`, `isolated`)를 포함한다. 영역 경계는 `--strict`
  임계값 계산과 일치한다

- `graph --format dot` 출력에서 순환 의존성에 참여하는 정점을 붉은색(`color="#d9383a"`,
  `fontcolor="#d9383a"`)으로 강조 표시 (madge 패리티). Tarjan SCC 알고리즘으로 순환을
  탐지하며, 순환이 없는 그래프의 DOT 출력은 바이트 단위로 동일하게 유지된다

- HTML 내보내기 및 사영에서 `.dart::` 문자열 휴리스틱에 의존하던 것을 `GraphNode`의
  명시적 `isLibrary` 불리언 플래그로 대체. 파일명에 `::`가 포함된 라이브러리가 정확하게
  분류된다. 분석 캐시 직렬화 스키마 버전이 `v3`으로 증가(캐시 identity는 불변)하여
  직렬화된 JSON·DOT·Mermaid 출력 변경 없이 이전 분석 캐시를 자동으로 재분석한다

- `bridges` 3개 진단 패밀리 전반의 문법 일치 수정(N ≥ 2인 `unscanned-*` limitation의
  복수형 명사 표기와 N = 1인 dynamic-* 단수형 동사 일치)

## 0.6.0

- **파괴적 변경(라이브러리 API)**: 공개 라이브러리 표면
  (`package:dartograph/dartograph.dart`)을 실제로 지원하는 범위로 좁혔다. CLI
  동작·종료 코드는 불변이다.
  - `querySymbol` 제거 — `tool/` 벤치마크만 쓰던 `SymbolQuerySession`의 1회성
    래퍼다. 대신 `SymbolQuerySession`을 만들고 `query`를 호출한다
  - `CodeGraph.usageEdgesFrom` 제거(제품 호출자 없음; `CodeGraph.edges`를
    필터링)
  - `SymbolQuerySession.analysis`(`ReachabilityResult` 필드)가 더 이상 공개가
    아니다. 세션이 `query --baseline` 흐름을 위해 `deadDeclarations`(불변
    `List<DeadFinding>`)를 노출해, 공개 멤버가 export되지 않은 타입을 참조하지
    않는다. 도달성 질문은 각 문서가 심볼의 도달성 상태를 싣는
    `SymbolQuerySession.query`가 답한다. `ReachabilityResult`·
    `ReachabilityExplanation`은 내부로 남고 `DeadFinding`은 이제 export된다

- `bridges` pub workspace 감지가 멤버십을 검증한다. pubspec에
  `resolution: workspace`를 선언한 패키지는 가장 가까운 조상 `workspace:` 루트가
  그 패키지를 그럴듯하게 나열할 때 조인된다 — URL 정규화 후 명시 경로를 일치
  확인하고, 글롭 항목과 목록이 아닌 `workspace:` 값은 보수적으로 인정한다.
  패키지를 빠뜨린 잘 구성된 명시 경로 목록일 때만 스캔 루트로 폴백하고 새
  `pub-workspace-member-not-listed` limitation을 실어, 잘못 구성된 workspace가
  isthmus 조인 기준을 조용히 어긋내지 않는다

- SARIF 출력이 이미 절대 URI인 소스를 더 이상 손상시키지 않는다. 소스가
  `file:`(root 밖 경로)·`package:`(의존)인 dead finding은 `/`로 쪼개 재인코딩
  (`file:///a.dart`가 `file%3A///a.dart`로 깨지던)하지 않고 그대로 통과한다.
  project 상대 경로는 기존 세그먼트별 인코딩(백슬래시·퍼센트 안전)을 유지한다

- HTML 그래프 출력이 파일명에 `::`를 담은 라이브러리를 이제 올바르게 분류한다
  (임의 `::` 대신 `.dart::` 선언 경계 사용). 그런 라이브러리가 더 이상 member로
  표시되지 않고, 표시 이름이 첫 `::`에서 잘리지 않는다

- README를 명료하게 개정(영어 정본·한국어 쌍둥이); 동작 변경 없음

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
  - bridges 제어문자 거부 **메시지**를 "a fact value or source path contains
    control characters"로 정정 — 메시지 전용이고 동작은 불변이다: 소스 경로
    검증은 0.3.0부터 있었고, 빈 이름은 throw가 아니라 `empty-bridge-names`
    limitation으로 건너뛰므로 기존 "is empty" 귀속이 도달 불가/오귀인이었다

- 인덱싱을 개선했다 — 출력 byte 동일, 실측 -28% (감사 P1/P2/P9/P10, 신규
  `tool/benchmark_index.dart` A/B 하네스로 측정 — graph·dead·query·
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

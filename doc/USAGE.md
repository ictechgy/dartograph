# 설치와 사용

## 설치

dartograph 0.15.1은 Dart SDK 3.11 이상에서 동작하는 순수 Dart 패키지다.

```bash
dart pub global activate dartograph 0.15.1
dartograph --version
```

Dart 3.11 이상은 `dart install`로도 설치할 수 있다. pub.dev 지정자는
`dart install dartograph`이고, 소스 체크아웃에서는 절대 경로 지정자가
동작한다(상대 `path` 지정자는 SDK 헬퍼 패키지 제약으로 실패한다 —
2026-09 Dart 3.13.3 실측):

```bash
dart install dartograph            # pub.dev 릴리스
dart install 'dartograph@{path: /absolute/path/to/dartograph}'
```

`dart install`은 실행 파일을 AOT 컴파일해
`~/Library/Application Support/Dart/install/bin`(macOS 기준)에 놓는다.
실측: 설치본 `dartograph --version` → `dartograph 0.10.0`, 소스
체크아웃 대상 `dead --kinds file` → 발견 보고·종료 1 (2026-09,
Dart 3.13.3/macOS arm64). `pub get`을 실행하지 않은 패키지 분석 등
Dart SDK가 필요한 경로는 AOT 설치본에서도 PATH의 SDK를 찾는다.

저장소 소스에서 실행할 때는 `dartograph` 대신 `dart run dartograph`를 쓴다.

## 명령

```text
dartograph init [--force] [<package-root>]
dartograph graph --format <dot|json|mermaid|html|anon> [--level <file|type|symbol>] [--collapse <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph dead --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--baseline <file>] [--since <ref>] [--kinds <csv>] [--closed-app] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph dead --explain <symbol-id> --format json [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph dead --report-test-only --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--since <ref>] [--kinds <csv>] [--closed-app] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph dead --report-redundant-public --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--since <ref>] [--kinds <csv>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph deps [--format <text|json|markdown|github-actions|sarif>] [--kinds <csv>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph dup [--format <text|json|markdown|github-actions|sarif>] [--min-tokens <n>] [--kinds <csv>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph baseline --write <file> [--closed-app] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph query <symbol-id-or-name> [--baseline <file>] [--depth <n>] [--limit <n>] [--with-source] [--source-context <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph query --batch <requests.json> [--baseline <file>] [--depth <n>] [--limit <n>] [--with-source] [--source-context <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph compare [--format <text|json|sarif>] [--incremental <dir>] [--workspace] [--record <dir>] <before-package-root> <after-package-root>
dartograph affected [--format <text|json|sarif>] [--incremental <dir>] [--workspace] [--record <dir>] <git-ref> <package-root>
dartograph impact --since <git-ref> [--format <text|json|markdown|github-actions|sarif|test-list>] [--depth <n>] [--limit <n>] [--fail-on <none|low|medium|high>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph impact --changed <changes.json> [--format <text|json|markdown|github-actions|sarif|test-list>] [--depth <n>] [--limit <n>] [--fail-on <level>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph impact --symbol <symbol-id> [--format <text|json|markdown|github-actions|sarif|test-list>] [--depth <n>] [--limit <n>] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph skill [--install <skills-directory> [--force]]
dartograph setup [--target <claude|cursor|codex|opencode>] [--install [<package-root>] [--force]] [--uninstall [<package-root>]]
dartograph runtime [--verify|--no-verify] [--format <text|json|markdown|github-actions|sarif>] [--dart-define KEY=VALUE]... [--env KEY=VALUE]... [--limit <n>] [--kinds <csv>] [--statuses <csv>] [--fail-on <none|low|medium|high>] [--execute <dart-entrypoint>] [--workspace] [--record <dir>] <package-root>
dartograph history --ledger <dir> [--commit <sha>] [--format <text|json>]
dartograph mcp
dartograph bridges --format json [--project <shared-root>] <package-root>
dartograph bridges --messages --format json [--project <shared-root>] <package-root>
dartograph bridges --events --format json [--project <shared-root>] <package-root>
dartograph cycles [--format <text|json|sarif>] [--strict] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph cycles --explain <symbol-id> [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph rules --config <yaml-file> [--format <text|json|sarif>] [--strict] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph rules --config <yaml-file> --explain <symbol-id> [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
dartograph metrics [--format <text|json|sarif>] [--strict] [--incremental <dir>] [--workspace] [--record <dir>] <package-root>
```

`--incremental <dir>`는 분석·색인 명령(graph·dead·deps·query·compare·affected·
impact·baseline·cycles·rules·metrics)이 받는다. 디렉터리에 파일별 사실 캐시를 두고 다음
실행에서 바뀐 파일과 그 파일을 import·export하는 폐쇄만 다시 해석한다. 산출물은
전체 해석과 byte 동일하다. 캐시가 없거나 손상됐거나 스키마가 다르거나 쓸 수 없으면
전체 해석으로 폴백하고 오류로 끝내지 않는다(쓸 수 없을 때만 그 사실을 limitation으로
남긴다). 캐시 디렉터리는 프로젝트마다 따로 쓴다. 널리 import되는 파일을 바꾸면
폐쇄가 사실상 전체에 가까워 이득이 줄어든다(변경 없음·잎 파일 변경에서는 크다).

같은 명령에 `runtime`을 더해 `--workspace`를 받는다 — pub workspace 집계를
옵트인한다. 루트 pubspec의 `workspace:` 목록에 있는 멤버를 하나의 그래프로 함께
분석한다(집계하지 않으면 기존처럼 `workspace-members-not-indexed`로 보고된다).
각 멤버의 표준 소스 디렉터리(lib·bin·example·integration_test·test)가 분석에 합류하고
멤버의 `lib/<name>.dart`는 공개 API 보존을 유지하며, `deps`는 패키지마다 자기
pubspec으로 감사해 각 발견이 어느 매니페스트(`manifest`) 것인지 표시한다.
디렉터리·pubspec이 없는 멤버와 symlink인 멤버 경로는 건너뛰고 보고한다(건너뛴
멤버의 소스는 루트 표준 디렉터리 안에 있어도 색인하지 않는다). `workspace:` 멤버를
선언하지 않은 루트, 선언된 멤버가 전부 건너뛰어진 경우, 잘못된 패키지 이름의 멤버
pubspec은 분석 실패(exit 2)다. 멤버의
`dartograph.yaml`은 읽지 않는다 — 루트 설정이 집계 전체에 적용되고 무시된 멤버
설정은 limitation으로 보고된다. 집계 결과는 단일 패키지 스캔과 다른 캐시 키를 쓴다.

## 검증 원장

`--record <dir>`를 주면 그 실행 하나를 `<dir>/ledger.jsonl`에 한 줄로 덧붙인다.
각 줄은 도구 버전·UTC 시각·명령·종료 코드·관측한 Git `HEAD`(계산하지 못하면 null)·
입력 플래그·보고한 문제 식별자를 담는다. `--env`·`--dart-define`은 값이 비밀일 수
있어 **키만** 남긴다. 파일은 append-only다 — 기존 줄을 다시 쓰거나 지우지 않는다.

`history --ledger <dir> [--commit <sha>] [--format text|json]`가 원장을 읽어
되돌려준다. `--commit`은 그 SHA의 실행만 고른다. 쓰기가 중단돼 마지막 줄이 잘리면
읽기가 그 줄을 건너뛰고 `ledger-skipped-lines: N` limitation으로 보고한다(원장은
고치거나 지우지 않으며, 다음 `--record`는 잘린 줄을 개행으로 닫아 새 줄로 이어 쓴다).
원장 쓰기 자체가 실패해도 분석 결과와 종료 코드는 그대로이고 stderr에 진단 한 줄만
남는다. 원장은 도구 버전·시각 같은 관측값을 담으므로 그 자체는 결정적 산출물이
아니다(제품 출력의 결정성 계약과 무관하다).

명령마다 "문제 식별자"가 다르다 — `dead`는 finding ID, `cycles`는 끊을 후보 간선,
`rules`는 위반 규칙·간선, `metrics`는 임계 초과 라이브러리, `runtime`은 미충족·미판정
사실, `impact`는 피영향 심볼이다. 문제를 정의하지 않는 명령(graph·query·compare·
affected·baseline)은 빈 목록이다.


`init`은 프로젝트 루트에 주석 달린 `dartograph.yaml` 설정 파일 템플릿을 생성한다.
이미 파일이 존재하면 안전을 위해 중단(exit 64)하며, `--force`를 전달하면 덮어쓴다.
대상 디렉터리에 `pubspec.yaml`이 없으면 stderr로 경고를 낸다 — 첫 pubspec 이전의
스캐폴딩도 지원하지만 잘못된 디렉터리 실수를 조용히 넘기지 않기 위해서다.

`skill`은 에이전트 스킬 문서를 출력한다. `--install <skills-directory>`는
`<skills-directory>/dartograph/SKILL.md`에 기록하고 성공·충돌 메시지에 그 경로를
표시한다. 기존 파일이나 링크가 있으면 exit 64로 중단하며 `--force`로 덮어쓴다.
그 자리의 심볼릭 링크는 대상을 따라가지 않고 링크 자체를 교체한다.

`setup`은 에이전트 MCP 연동 설정을 만든다. `--target`은 `claude`(기본),
`cursor`, `codex`, `opencode` 중 하나를 고른다. 인자 없이 실행하면 그 타깃의
결과물을 검토용으로 출력한다 — `claude`는 PostToolUse 훅
스크립트(`dartograph-impact.sh`), `settings.json`에 병합할 hooks 블록,
`.mcp.json` 문서, 지시 파일에 싣는 관리 안내 블록을 보여준다.

`--install [<package-root>]`은 타깃별 설정 파일에 dartograph 항목을 **병합**한다 —
기존 키는 보존하고, 이미 등록된 항목은 건너뛰며, 깨진 JSON이나 예상 밖 타입의
설정은 덮어쓰지 않고 실패(exit 2)한다.

- `claude`: `.claude/hooks/dartograph-impact.sh`를 쓰고(실행 비트 부여),
  `.claude/settings.json`의 `hooks.PostToolUse` 목록과 `.mcp.json`의
  `mcpServers`에 병합한다. 또 `CLAUDE.md`(없고 `AGENTS.md`만 있으면
  `AGENTS.md`, 둘 다 없으면 `CLAUDE.md`를 만든다)에
  `<!-- dartograph:begin -->`…`<!-- dartograph:end -->`로 감싼 관리 안내
  블록을 병합한다 — 어떤 질문에 어떤 dartograph 명령을 쓸지 라우팅을 매
  세션 컨텍스트에 올리기 위해서다. 표지가 짝 없이 있거나 중복이면 사람이
  고친 흔적으로 보고 실패(exit 2)한다. 생성된 훅은 Dart 파일 편집마다
  `dartograph impact --changed --fail-on high`를 실행해 발견이 있으면 종료 2로
  에이전트에게 보고한다. `<package-root>`가 필요하다.
- `cursor`: `<package-root>/.cursor/mcp.json`의 `mcpServers`에 병합한다.
- `opencode`: `<package-root>/opencode.json`의 `mcp`에 `type: local` 항목을
  병합한다.
- `codex`: Codex는 프로젝트 설정을 읽지 않고 전역 `$CODEX_HOME/config.toml`
  (기본 `~/.codex/config.toml`)만 읽는다. 따라서 `<package-root>` 없이
  `--install`만 주면 전역 파일에 `[mcp_servers.dartograph]` TOML 표를
  병합한다 — `<package-root>`를 주면 usage(64)다. 다른 표·키는 그대로
  보존한다. 점 키(`mcp_servers.dartograph.command = …`)·배열 표 등
  표가 아닌 모양의 dartograph 정의, 또는 `mcp_servers`가 표가 아닌
  값(인라인 표·배열·스칼라)으로 정의돼 있으면 덧붙이는 것만으로 파일
  전체가 깨지므로 덮어쓰지 않고 실패(exit 2)한다.

`--uninstall [<package-root>]`은 `--install`이 만든 dartograph 항목만 되돌린다 —
`claude`는 훅 등록·MCP 항목을 지우고 생성한 훅 스크립트도 지우며(내용이 우리
것일 때만), `CLAUDE.md`·`AGENTS.md` 양쪽에서 관리 안내 블록을 벗겨낸다.
파일 전체가 현재 생성 블록과 byte가 같은 파일(설치가 만든 것)만 파일째
지운다. 블록 안쪽을 사용자가 고쳤거나 이전 버전이 쓴 다른 문안의 블록,
다른 내용이 섞인 파일은 "설치가 만든 파일"로 증명할 수 없으므로 파일은
남기고 블록만 제거한다 — 이때 파일이 비어 있게 남을 수 있다. 그 경계에서
어느 파일도 쓰기 전에 두 파일의 결과를 모두 계산해 부분 uninstall을
피하고, 깨진 표지는 실패(exit 2)다. 없는 파일·항목은 성공으로 넘어간다.
`--force`는 생성 스크립트와 dartograph MCP 항목·안내 블록을 교체한다.

PATH의 `dartograph`가 필요하며 MCP 호출·유료 서비스·로그인·텔레메트리는 없다.
Codex 전역 설정 경로는 `CODEX_HOME` 환경 변수로 바꿀 수 있다.

`graph --level`은 그릴 해상도를 고른다. `file`은 모든 선언을 소속 라이브러리로,
`type`은 멤버를 최상위 선언 컨테이너로 접고, `symbol`(기본)은 그래프를 있는 그대로
그린다(기본값에서 사영은 항등이라 수준 처리 자체는 출력을 바꾸지 않는다 — 단,
0.4.1에서 `graph --format json`에 추가된 조건부 `isEnumConstant` 필드는 해상도와
무관한 별도 변경이다). 접힌 라이브러리·컨테이너
내부 관계는 자기 순환이 되어 사라지고, 남는 간선은 양끝이 대표로 바뀌고 종류별로
중복 제거된다. 조상 정점이 없는 선언은 그대로 남는다. dartograph는 패키지 하나를
분석하므로 cartograph의 module 해상도에 대응하는 것은 없다(패키지로 접으면 단일
정점) — `file`이 가장 거친 해상도다.

`graph --collapse <n>`은 `--level file` 그래프를 경로 앞 n세그먼트로 요약한다
(dependency-cruiser `--collapse` 대응): `project:lib/src/a/x.dart`는 n=2에서
`project:lib/src`로, `package:name/src/x.dart`는 n=1에서 `package:name`으로 접힌다.
세그먼트가 n 이하인 ID는 그대로다. 폴더 정점은 파일이 아닌 집계이므로 `sourceUri`·
`line` 같은 위치를 갖지 않는다. 같은 폴더로 접힌 관계는 자기 순환이 되어 사라진다.
`--collapse`는 `--level file`과만 결합하며(그 외 usage 64) 값 빠짐·중복 플래그·
1 미만·비정수는 usage(64)다. 두 옵션은 모든 `--format`에 적용된다.

`graph --format html`은 외부 CDN·스크립트·폰트 참조가 없는 단일 자기완결 파일이다.
네트워크가 막힌 사내망이나 CI 아티팩트에서도 열리고, 그래프 사실은
`<script type="application/json">` 페이로드에 실려 캔버스 힘 기반 배치·검색·팬·줌으로
렌더링된다. 400정점을 넘으면 연결이 많은 정점부터 남기고 잘라 냈다는 사실을 페이지와
페이로드(`truncatedFrom`)에 적는다 — 전체 그래프는 `--format dot`을 쓴다. limitations는
헤더의 접히는 목록과 페이로드 양쪽에 실린다.

`graph --format anon`은 버그 리포트 공유용 JSON이다. 문서 모양은 `--format json`과
같고 정점 ID·소스 URI·간선 양끝·limitation 문구의 경로만 결정적으로 치환한다
(식별 문자열 → `s0`, `s1`, … 토큰; 스킴·디렉터리 계층·`::`·멤버 점 구분·확장자는
보존, `lib`·`src` 같은 관용 어휘는 경로와 선언 이름 어느 쪽에도 그대로). 같은
그래프는 항상 같은 문서를 내므로 출력끼리 직접 비교할 수 있다. 치환은 그래프에
실린 다중 세그먼트 경로 전체만 대상이라 limitation 문구가 그래프에 없는 경로를
담으면 그 문자열은 그대로 남는다.

`dead`는 보존 루트에서 도달할 수 없는 선언과 파일을 보고하지만 삭제 판정을 하지 않는다.
`--format`은 `text`(기본)·`json`·`markdown`·`github-actions`·`sarif`다 — 사람은 `text`·
`markdown`, CI는 `github-actions`·`sarif`, 자동화는 `json`을 쓴다. `markdown`은 `dead`·
`dead --report-test-only`·`dead --report-redundant-public` 모두에서 표와 limitation
목록을 낸다. `codeowners`는 `--codeowners <file>`로 준 CODEOWNERS 파일로 각 finding의 소스 경로 소유자를 찾아 소유자별로 묶는다(마지막 일치 규칙이 이기고 `*`/`**`, `/` 고정을 지원하는 CODEOWNERS 표현의 부분집합). 규칙에 없는 finding은 `(unowned)`에 모인다. `--format codeowners`에는 `--codeowners`가 필수이고 다른 형식에는 붙일 수 없다.
`--explain`은 도달 경로나 미도달 근거를 JSON으로 낸다. `baseline`은 현재 finding을 기록하고,
`--since`는 전체 그래프를 만든 뒤 Git 기준 ref 이후 바뀐 파일로 보고 범위를 좁힌다.
심볼릭 링크 소스는 양방향으로 매치된다 — 링크 파일 자체가 바뀐 경우(링크 경로)와
링크 대상이 바뀐 경우(해석된 실 경로) 모두 변경 집합에 속한다.
`--explain`은 단일 대상의 전체 근거를 묻는 명령이라 `--baseline`·`--since`와 함께 쓰지 않는다.
그래프에 없는 ID는 `known: false`와 종료 코드 64로 구분한다.

`dead --closed-app`은 공개 API 보존(`lib/<package>.dart`가 export하는 선언 전부를
보존 루트로 두는 정책)을 끈다. **라이브러리가 아니라 독립 실행 앱**(Flutter 앱·CLI
실행 파일)을 분석할 때 쓴다 — 앱에는 외부 소비자가 없으므로 `main`에서 도달하지
못하는 공개 선언도 finding으로 보고된다. 진입점·테스트·annotation·`entry_points`
설정·build_runner·JS/FFI 외부 바인딩·억제 마커 등 나머지 보존 근거는 그대로다.
보고서는 `closed-app-analysis` limitation으로 이 모드를 명시한다. 외부에 게시되는
패키지에 쓰면 공개 API가 소비자 없이 dead로 보고되므로 **게시 라이브러리에는 쓰지
않는다**. `--report-redundant-public`(이미 공개 선언만을 다른 질문으로 다룸)과의
결합은 usage(64)다. `baseline --write <file> --closed-app`은 같은 루트 의미로
finding을 기록하므로 `dead --closed-app --baseline <file>`과 짝이 된다 — 모드를
다르게 한 baseline은 finding 지문이 어긋나 억제가 적용되지 않는다.

`dead --report-test-only`는 다른 질문을 답한다: 테스트 디렉터리(`test/`·`integration_test/`
등)의 보존 루트를 빼고 다시 도달성을 계산해, **프로덕션 선언인데 테스트에서만 도달되는**
것을 고른다. 이들은 죽은 코드가 아니라(삭제하면 테스트가 깨진다) "테스트가 유일한 호출자"
라는 관측이므로 `info` 심각도로 보고되고 **finding이 있어도 종료 코드 0**이다(빌드를 실패
시키지 않는다). 테스트 디렉터리 내부 선언과 `@visibleForTesting` 프로덕션 선언(테스트
디렉터리 밖이라 루트로 남음)은 보수적으로 답에서 제외한다. 단일 대상 질의인 `--explain`,
dead finding을 억제하는 `--baseline`과는 결합하지 않으며 `--since`·`--format`은 허용한다.

`dead --report-redundant-public`도 다른 질문을 답한다: 살아 있는 **공개 선언**(이름이
`_`로 시작하지 않는다) 중 들어오는 사용 참조가 전부 자기 라이브러리 안에서 시작하는
것을 고른다. 이 관측만으로는 라이브러리 비공개로 좁혀도 깨지는 참조가 없다(Periphery
`redundant public accessibility` 대응). 삭제 권고가 아니라 가시성 관측이므로 `info`
심각도이고 **finding이 있어도 종료 코드 0**이다. 보존 루트(진입점·pragma·공개 API
barrel·플러그인 등 외부·도구가 유지를 선언한 선언), enum 상수, 공개 계약을 이행하는
override, `<unnamed-extension@…>` 마커는 보수적으로 제외한다. 단일 패키지 분석이라
외부 소비자는 보이지 않는다 — **게시된 패키지의 공개 API는 이 관측으로 좁히지 말 것**.
`--report-test-only`와의 동시 사용, `--explain`·`--baseline`과의 결합은 usage(64)다.

`deps`는 pubspec 선언과 소스의 `package:` import/export 관측을 대조하는 의존성 위생
감사다. finding은 네 종류다: `unused-dependency`(선언됐는데 어느 소스도 import하지
않음), `unused-dev-dependency`(dev 선언의 같은 관측), `dev-dependency-in-lib`
(dev 의존을 `lib/` 안에서 참조 — 게시 패키지가 깨지는 배선), `undeclared-dependency`
(참조하는데 어느 선언에도 없음). `--format`은 `text`(기본)·`json`·`markdown`·
`github-actions`·`sarif`다.

`deps --workspace`는 루트와 각 멤버를 **자기 pubspec 기준으로 따로** 감사한다 —
멤버 소스의 `package:` 관측은 그 멤버의 선언·dev 선언·tool 근거와 대조되고,
finding은 소유 pubspec의 `manifest` 필드(`pubspec.yaml`,
`pkgs/core/pubspec.yaml` 등 프로젝트 상대 경로)를 싣는다. JSON의 finding 객체에만
필드가 추가되고, text는 각 warning 줄이 그 pubspec 경로로 시작하며,
Markdown은 manifest가 있는 finding이 있을 때만 Manifest 열을, GitHub
Actions의 `file=`과 SARIF의 artifact URI는 해당 pubspec을 가리킨다.
`--workspace` 없이는 출력 형태가 그대로다 — `manifest` 필드·열은 나타나지
않는다.

사용은 **관측**으로만 판정한다 — `package:` 지시문이 없어도 도구 계약이 요구하는
의존은 사용으로 친다: pubspec `executables`에 노출된 실행 파일, `build.yaml`의
`builders`·`post_process_builders`, `analysis_options.yaml`이 include하거나
analyzer plugin으로 올린 패키지. 이 근거는 finding의 `evidence`와 보고서의
`tool-usage:` limitation에 실린다. 런타임 로딩(`Isolate.spawnUri` 등), 생성 코드가
import하는 패키지, 에셋 경로만의 참조는 이 감사에 보이지 않으며 그 사실이 limitation으로
남는다. `dependency_overrides`는 사용 관측을 만들지 않으므로 미사용으로 보고하지
않는다. finding이 있으면 종료 코드 1이다 — 삭제 지시가 아니라 검토 목록이다.

`dup`은 소스 안의 중복 코드 블록을 찾는다. 정규화한 토큰 창(window)을 모든 파일에서
대조해 `--min-tokens`(기본값) 이상 반복되는 비겹침 블록을 `duplicate-block`
finding으로 보고한다. 구조적 일치일 뿐 의미적 동등성은 검증하지 않는다 — 이름만
다른 사본도 잡지만, 같은 모양이어도 의도된 병행 구조일 수 있다. 생성 코드는 제외되고,
분석된 소스 안에서만 대조하므로 finding은 리뷰 후보이지 삭제·병합 지시가 아니다.

`--kinds <csv>`는 `dead`(`declaration`,`file`)·`deps`(4종)·`dup`(`duplicate-block`)이
보고하는 finding 종류를 좁힌다. `runtime`에서는 보고하는 사실 카테고리(`env`,
`dynamicLoad`, `config`, `asset`, `external`)를 좁히고, `runtime --statuses <csv>`는
판정 절(`present`,`defaulted`,`missing`,`unverified`)을 좁힌다 — 판정이 없으므로
`--no-verify`와는 결합하지 않는다(usage 64). 그래프·지문·baseline·위험도는
그대로이고 보고만 필터된다 — `dead`·`deps`·`dup`은 보고할 finding이 남지 않으면
종료 코드 0이지만, `runtime --fail-on`은 필터 전 전체 위험도로 판정하므로 목록이
비어도 종료 코드 1을 반환할 수 있다. 모르는 종류·빈 값은 usage(64)이고,
`dead --explain`과는 결합하지 않는다. `--limit`은 필터된 목록에 적용된다.

`query`는 일치한 심볼의 양방향 관계, 멤버, 보존 경로, baseline 상태를 답한다. 찾지 못한
경우에도 `notFound`와 `limitations`를 함께 낸다.
`--with-source`는 보고된 모든 선언 위치에 그 소스 줄을 `source`(줄 번호·텍스트 목록)로 덧붙이고, `--source-context <n>`은 위치 앞뒤 n줄까지 넓힌다(기본 0 — 선언 줄만). `project:` 상대 경로만 읽는다 — 절대 경로와 `..`로 루트를 벗어나는 경로는 거부한다. 경계는 경로 기준이다 — 루트 안 심볼릭 링크가 밖을 가리키면 인덱서와 같은 대상을 읽는다. 읽지 못한 위치는 조용히 생략한다. `--source-context`는 `--with-source` 없이 쓰면 usage 64다.

기본 `bridges`는 Flutter MethodChannel
채널·메서드 사실을 GRAPH-EXCHANGE v1 JSON으로 낸다(문서 계약은
[GRAPH-EXCHANGE.md](GRAPH-EXCHANGE.md) 참조). `bridges --messages`는 개발 소스
전용 opt-in 경로로, 실제 BasicMessageChannel `send` 호출만 bridge-facts v2
(`transport: basic-message-channel`, `kind: message-send`)로 낸다. 채널 생성은 send로
세지 않으며 MethodChannel의 method 필드도 만들지 않는다. 동적 이름은 원래 표현식을
보존하고, `channelPrefix`는 AST가 증명한 decoded 비어 있지 않은 문자열 interpolation
선행 literal일 때만 후보 근거로 낸다. prefix는 완전한 runtime 주소·instance identity의
증명이 아니며, 이 경로는 0.9.0에 새로 추가되었다.
`bridges --events`는 같은 opt-in 형태로 EventChannel `receiveBroadcastStream`
호출만 bridge-facts v2(`transport: event-channel`, `kind: stream-listen`)로 낸다.
정적으로 식별한 호출을 반환 스트림의 소비 여부와 무관하게 `stream-listen`으로
기록한다 — 호출 실행·리스너 부착·활성 구독·이벤트 수신의 증명이 아니다.
임의의 `.listen()`이나 EventChannel로 입증되지 않은 수신자에서 stream 사실을
추론하지 않고, 미귀속 호출은 `unresolved-stream-listens`로 센다. `--messages`와
`--events`는 서로 다른 transport 문서라 함께 쓸 수 없고(usage 64), 두 문서가
필요하면 두 번 실행한다. 어느 문서든 dart:ffi·package:jni 계열 import를 관측하면
채널 사실과 별개로 `unscanned-ffi-interop` limitation에 파일 수를 싣는다 —
FFI/JNI 경계는 채널 조인 범위 밖이다. 패키지의
`lib/<package-name>.dart`가 export한 공개 선언과
공개 멤버는 외부 소비자 API로 보존하고 `query`에서 `reason: publicApi`로 설명한다.

`bridges --project <shared-root>`은 모노레포 조인용 공유 루트를 선언한다. 스캔 범위는
위치 인자(`<package-root>`) 그대로이고, 문서의 `project` 필드와 `location.path`가
`<shared-root>` 기준이 된다(`package-root`를 포함하는 기존 디렉터리여야 하며 realpath로
정규화된다 — 아니면 usage 64). pubspec에 `resolution: workspace`를 선언한 패키지는
`--project` 없이도 `workspace:` 키를 가진 가장 가까운 조상 pubspec 디렉터리(pub
workspace 루트)를 프로젝트로 자동 사용한다. 감지에 실패하면(조상 루트 부재·pubspec
파싱 불가) 스캔 루트로 폴백하고 `pub-workspace-root-not-found`·
`pub-workspace-pubspec-unparsed` limitation으로 알린다 — isthmus는 한 번의 조인에 들어오는
문서들의 `project` 문자열 정확 일치를 요구하므로(fail-closed), 기준이 조용히 어긋나는
것보다 원인을 남기는 쪽이 안전하다. 문서 생산 후 `project`를 손으로 고쳐 쓰는 것은
provenance를 깨므로 금지(GRAPH-EXCHANGE). 우선순위는 `--project` > workspace 감지 >
스캔 루트다.

`// dartograph:ignore` 줄 주석은 그 아래 선언의 dead 보고를 억제한다. 마커가 주석 본문
**시작**에 와야 지시문이다: 산문이 마커를 언급해도 오해석되지 않고, doc comment(`///`)와
블록 주석은 지시문이 아니며, `// dartograph:ignore — reflection 진입점`처럼 이유를 뒤에
적을 수 있다. 마커와 선언 사이에 빈 줄이나 다른 주석이 있어도(코드가 끼지 않는 한)
유효하고, `void foo() {} // dartograph:ignore` **같은 줄 꼬리 주석은 다음 선언의 억제로
해석되지 않는다**. 변수·필드는 감싸는 선언에 붙은 마커가 적용된다
(`int a = 1, b = 2;`면 두 변수 모두). 선언이 아닌 위치(library 지시문·파일 끝 등)의
마커는 오류 없이 무시된다.

억제된 선언은 `retentionReason: inlineIgnore` 보존 루트가 되어 `dead --explain`·`query`·
compare가 그 근거를 답하고, 다른 보존 이유가 함께 있어도 사용자 지시가 먼저 답해진다.
보존은 도달성 루트로 동작하므로 **억제된 선언이 참조하는 것도 도달 가능해져 보고에서
함께 사라진다** — Periphery의 의도적 진입점과 같은 모델이며, 해당 finding만 억제하는
baseline과 다르다. 대량·파일 단위 억제는 baseline을 쓴다(파일 finding은 주석으로
억제되지 않는다). 멤버는 따라 억제되지 않는다.

`query --depth <n>`(기본 1)은 사용 관계(`usedBy`·`dependsOn`)를 n단계까지 따라가며, 각
이웃의 `depth` 필드가 출발 심볼에서 몇 걸음인지 나타낸다. 한 이웃에 닿는 간선 종류는 모두
모아 `edges`에 싣고, 같은 이웃이 여러 경로로 닿으면 최단 깊이 한 번만 보고한다.
`--limit <n>`은 방향별로 보고할 이웃 수를 제한하며, 제한으로 생략하면 해당 방향의
`truncated`가 `true`가 되고 생략된 이웃은 더 확장하지 않는다. 포함 관계(`members`·
`declaredIn`)는 사용 관계가 아니므로 `--depth`와 무관하게 항상 한 단계다. 재귀처럼 자기
자신으로 향하는 사용 간선은 자기 자신의 이웃에서 **모든 depth(기본값 포함)에서 제외**된다
— 옛 1-hop 순회는 포함했으므로 기본 출력의 좁은 동작 변경이다(cartograph와 같은 의미).
두 값 모두 1 미만·비정수·값 빠짐·중복 플래그는 usage(64)다. `--depth`·`--limit`은
`--batch`·`--baseline`과 함께 쓸 수 있다.

`query --batch`는 JSON 문자열 배열을 읽는다. 요청은 1–1000개, 파일은 1 MiB 이하이며
요청 순서와 중복을 유지한다. 예: `["ApiClient", "ApiClient.fetch", "Missing"]`.
그래프·도달성·이웃 색인은 한 번만 만들고 baseline도 한 번 적용한다. 출력은
`format: symbol-query-batch`, `version: 1`, `results: [...]`이며 각 결과는 단일 query
문서다. 하나라도 `notFound`이면 전체 종료 코드는 64지만 나머지 결과도 모두 반환한다.
`ambiguous`는 후보 목록과 함께 정상 결과로 반환한다. 자동으로 하나를 고르지 않는다.

`compare`에는 같은 프로젝트의 서로 다른 커밋을 checkout한 두 디렉터리를 넘긴다.
두 checkout에서 의존성을 준비하고 SDK·빌드 설정을 맞춰야 한다. 명령은 checkout이나
의존성 설치를 수행하지 않는다. `--since`의 보고 위치 필터와 달리 두 그래프를 비교한다.
출력은 `graph-comparison` 버전 1이며 추가·제거 정점/간선/루트와 `newlyUnreachable`,
`newlyReachable`, `newlyRetainedByMember`를 담는다. 기존에 존재한 선언의 미도달 전환에
`beforePath`, `removedEdgesOnBeforePath`, `removedRootsOnBeforePath`를 붙인다.
멤버에 의해 보존되던 선언은 `retainedByMember` witness를 별도로 표시한다.
이는 관측된 그래프 변화이며 단일 변경의 인과 증명이나 삭제 가능 판정은 아니다.
이름 변경은 삭제/추가로 나타난다. 두 입력의 한계를 함께 읽어야 하며 보고 성공은 코드 0이다.

`affected <git-ref>`는 Git 기준점(커밋·브랜치·태그·`HEAD~1` 등) 이후 변경된 라이브러리와
그에 전이적으로 의존하는 라이브러리를 JSON으로 답한다. 변경 파일이 귀속되는 라이브러리를
씨앗으로 import·export 간선을 역방향으로 건너며, 각 피영향 라이브러리에는 가장 가까운
변경 라이브러리까지의 최단 의존 사슬 `path`와 `depth`가 붙는다. part 파일의 변경은 호스트
라이브러리로 귀속된다. `--since`와 같이 전체 Git 이력이 필요하고(CI에서 full fetch),
심볼릭 링크 소스는 링크 경로와 해석된 실 경로 양방향으로 변경 집합과 매치된다.
출력 `changed`는 씨앗 라이브러리, `affected`는 그 종속자이며 둘은 겹치지 않는다.
영향 반경은 라이브러리(파일) 수준 관측이고, 나열되지 않은 라이브러리의 개별 선언이
영향받지 않았다는 증명은 아니다. 패키지 안에 있으면서 어떤 분석 대상 라이브러리에도
속하지 않는 변경 Dart 파일은 `changed-dart-files-without-library` 한계로 알린다.
삭제된 파일은 Git 변경 집합에 포함되지 않는다(`--since`와 같은 ChangedFiles 계약).
보고 성공은 영향 개수와 무관하게 코드 0이다.

`impact`는 같은 질문을 **수정 전에, 더 깊게** 답한다. `affected`가 라이브러리(파일)
수준 영향 반경만 내는 것과 달리, `impact`는 변경 씨앗에 사용 간선(`call`·`reference`·
`inheritance`·`implements`·`mixin`·`override`·`import`·`export`)으로 전이적으로
의존하는 **심볼**을 최단 사용 경로·깊이와 함께 나열하고, 변경 선언으로 들어오는
**호출 지점**(파일·줄·열), 변경 라이브러리를 (전이적으로) import하는 **관련 테스트
라이브러리**, 그리고 팩터별 **위험도**(0–100, `low`/`medium`/`high`)를 함께 낸다.
사람은 `text`·`markdown`, CI는 `github-actions`·`sarif`, 자동화는 `json`을 쓴다.

씨앗은 정확히 하나를 준다: `--since <git-ref>`(Git 변경 파일, `affected`와 같은
전체 이력·심볼릭 링크 양방향 매칭), `--changed <changes.json>`(프로젝트 상대 경로의
JSON 문자열 배열, 1–1000개·1 MiB 이하, `query --batch`와 같은 상한), 또는
`--symbol <symbol-id>`(한 심볼의 종속자). 둘 이상이거나 없으면 usage(64)다.

`--depth`는 전이 한계(기본 무제한), `--limit`은 **보고** 항목 수 제한이다(탐색과
개수·위험도는 제한하지 않고 잘린 수만 `truncated`로 알린다). `--fail-on <level>`은
전체 위험도가 그 수준 이상이면 종료 코드 1로 만든다(기본 `none`은 항상 0). 출력에는
`coverage` 블록이 있어 **변경 파일만 확인했을 때 누락됐을** 영향 심볼 수와 목록을
제시한다 — 사전 점검의 가치를 수치로 남긴다.

`--format test-list`는 영향받는 테스트 라이브러리의 프로젝트 상대 경로만 한 줄에
하나씩 낸다 — `dart test`의 인자로 곧바로 쓰는 소비 형식이다. 테스트 선택은
`--limit`의 영향을 받지 않고 항상 전체를 싣는다. 헤더·limitations를 붙이지 않으므로
파이프에 안전하다:

```bash
# 영향받는 테스트만 실행 (GNU xargs는 빈 입력 실행을 막는 -r 필요)
dartograph impact --since origin/main --format test-list . | xargs -r dart test

# 이식 가능한 가드 — 빈 목록이면 실행하지 않는다
tests=$(dartograph impact --since origin/main --format test-list .)
[ -n "$tests" ] && dart test $tests
```

빈 출력은 "영향받는 테스트 없음"이다 — 인자 없는 `dart test`는 전체 스위트를
실행하므로 빈 출력 가드는 필수다(macOS/BSD `xargs`는 빈 입력을 건너뛰지만 GNU는
`-r`이 필요하다). 목록이 비는 것은 "테스트가 안전하다"의 증명이 아니라 관측된
테스트 의존이 없다는 뜻이다. 줄 단위 `xargs`·따옴표 없는 `$tests` 확장은 공백이
들어간 경로를 나눠서 넘기므로, 경로에 공백이 있을 수 있으면 `xargs -d '\n'`(GNU)
나 `while IFS= read -r` 루프를 쓴다. `--fail-on`과 조합할 때는 파이프라인 마지막
명령의 종료 코드만 남으므로 `set -o pipefail`을 켜거나 결과를 변수에 담아
확인한다.

`--symbol`이 그래프에 없으면 `known:false`와 종료 코드 64로 구분한다(`query`·
`dead --explain` 계열과 같다). `impact`는 관측된 의존 도달성이지 삭제 판정이 아니며,
나열되지 않은 선언이 영향을 받지 않았다는 증명이 아니다.

`runtime`은 정적 import 그래프에 잡히지 않고 **실행 시점에만 드러나는 입력**을 찾고,
기본으로 이 환경에 대해 판정한다. 카테고리는 다섯이다: 환경변수·dart-define(`env`),
동적 로딩(`dynamicLoad` — `Isolate.spawnUri`, `Process.run`/`start`,
`DynamicLibrary.open`, `dart:mirrors`, `Function.apply`), 설정 파일·경로(`config`),
번들 에셋(`asset` — `pubspec.yaml`의 `flutter.assets` 선언과 `rootBundle`·
`Image.asset`·`AssetImage`), 외부 URL(`external`). 각 사실은 `present`(제공됨)·
`defaulted`(기본값으로 충족)·`missing`(이 환경에서 미충족)으로 판정되고, 정적으로
확정할 수 없거나 프로브할 수 없는 것은 이유와 함께 `unverified`에 남는다. 미충족·
미판정·외부 자원 수는 위험도(0–100)로 합산되고 `low`/`medium`/`high` 등급이 붙는다.
`--no-verify`는 판정을 끄고 탐지만 한다(위험도 없음).

`--env KEY=VALUE`·`--dart-define KEY=VALUE`는 반복 지정할 수 있고 같은 키는 마지막
값이 이긴다. 값 자체는 절대 출력되지 않는다 — "설정되었지만 빈 값"은 미설정과 다른
관측이므로 빈 값은 유효하고, 키가 비면(`=VALUE`) usage(64)다. 두 채널은 서로를
충족하지 않는다(dart-define과 프로세스 환경은 다른 입력이다). `--env`를 하나라도 주면
그 집합만 쓰고 프로세스 환경은 무시하며(hermetic), 주지 않으면 실제 프로세스 환경을
쓰고 그 사실을 `environment-source` limitation에 남긴다.

`--execute <dart-entrypoint>`는 **임의 코드를 실행한다**: 패키지 루트에서
해석된 Dart SDK(실행 중인 Dart VM → `DART_SDK` 환경변수 → PATH 순)로
`dart run <entrypoint>`를 띄우고 `--env` 값을 상속 환경 위에 덮어쓴 뒤
종료 코드와 stderr 요약(4 KiB 상한)을 실행 증거로 남긴다. SDK를 해석하지 못하면
실행을 건너뛰고 `execution`에 `reason`만 남긴다(`exitCode`는 null이다 — 실행
실패와 구분된다). 실행 실패는 위험 요인
(`execution-failed`, 30)이 되지만 나머지 보고는 그대로 나온다. 경로처럼 보이는 인자
(`.dart`로 끝나거나 경로 구분자를 포함)는 파일 존재를 요구하며 없으면 usage(64)다 —
패키지 실행 파일 이름은 `dart run`이 해석하므로 존재를 요구하지 않는다. 신뢰한
프로젝트에서만 쓴다. 실행과 출력 수집에는 합쳐서 60초 제한을 적용하고, 제한을 넘으면
직접 실행한 자식의 종료를 최대 5초 더 확인한다. 부모가 종료돼도 후손이 출력 파이프를
보유하면 `timedOut`으로 보고하며 파이프 수집을 중단한다. 후손 프로세스 전체를 종료하는
격리 기능은 제공하지 않는다. AOT 설치본도 `--execute`에는 `DART_SDK` 또는 PATH의
Dart SDK가 필요하다.

`--format`은 `text`(기본)·`json`·`markdown`·`github-actions`·`sarif`다. 사람은 `text`·
`markdown`, CI는 `github-actions`(`missing` 항목은 위험이 `high`면 `error`, 아니면
`warning`)·`sarif`를 쓴다. `--limit <n>`은 **보고** 항목 수 상한이다(탐지·판정·위험도는
제한하지 않는다 — `--limit`이 종료 코드를 바꾸면 게이트가 아니다). 생략한 수는 목록별로
`truncated`에 남는다. JSON 보고서의 `unverifiedReasonCounts`는 미판정 사실을 사유
접두사별로 센다(접두사가 비는 사유는 `unspecified`로 묶는다) —
`--kinds`·`--statuses`·`--limit`과 무관하게 판정된 전체 미판정 집합 기준이다. `--fail-on <level>`은 위험 등급이 그 수준 이상이면 종료 코드 1로
만든다(기본 `none`은 임계를 0으로 두어 항상 0이다). 종료 코드는 0(보고 성공), 1(위험
등급이 `--fail-on` 임계 이상), 2(분석 실패 — 없는 루트 등), 64(usage 오류, `--execute`
경로 없음)다.

`runtime`의 판정은 관측이지 실행 가능성 판정이 아니다. `missing`은 그 입력이 필수라는
뜻이 아니다 — 선택적 읽기와 필수 읽기를 구분하지 않는다. 외부 URL은 프로브하지 않고,
리플렉션·계산된 이름은 `<computed>`로 남기며, 표준 소스 디렉터리(`lib`·`bin`·`test`·
`example`·`integration_test`) 밖은 보지 않는다. 상대 경로는 패키지 루트 기준으로
확인하지만 실제 프로그램은 스크립트 URI나 작업 디렉터리 기준으로 열 수 있다. 탐지·판정
한계는 보고서의 `limitations`에 모두 실린다.

`rules --config`의 layers.yaml 스키마는 엄격하다. 설정 파일은 1 MiB 이하여야 한다(초과 시
분석 실패). `layers`는 `name`과 `match`(정점 ID와
`sourceUri` 양쪽에 걸리는 glob 목록)를 가진 목록이고 먼저 일치하는 레이어가 이긴다.
`rules`는 `name`·`from`(출발 레이어)·`allow` 또는 `deny`(정확히 하나, 대상 레이어 목록)를
가진다. 알려지지 않은 키나 `allow`/`deny`가 둘 다 있거나 둘 다 없으면 분석 실패(종료 코드 2)다.

```yaml
# layers.yaml
layers:
  - name: ui
    match: ["project:lib/ui/**"]
  - name: data
    match: ["project:lib/data/**"]
rules:
  - name: ui-must-not-reach-data-internals
    from: ui
    deny: [data]
```

`cycles --explain <symbol-id>`는 한 정점이 강결합 요소로 참여하는 순환과 각각의
`breakCandidate`(끊을 후보 간선)를 JSON으로 낸다. 한 정점은 최대 하나의 강결합 요소에
속하므로 `cycles`는 0개 또는 1개다. `rules --explain <symbol-id>`는 그 정점이 배치된
레이어, 배치를 결정한 `matchedPattern`·`matchedCandidate`, 그리고 그 레이어에서 출발하는
`rules`를 JSON으로 낸다. 어떤 레이어에도 매치되지 않으면 `layer`·`matchedPattern`·
`matchedCandidate`가 null이고 `rules`는 비어 있다(rules는 계속 `--config`를 요구한다).
두 `--explain` 모두 단일 정점 질의라 `--strict`와 결합하지 않으며, 그래프에 없는 ID는
`known: false`와 종료 코드 64로 구분한다. 알려진 ID는 순환·레이어 참여와 무관하게
종료 코드 0이다(이 명령들은 기본적으로 보고만 하므로 explain은 finding 게이트가 아니다).

모든 JSON 목록과 키는 결정적 순서로 출력된다. 같은 입력은 byte-for-byte 같은 결과를
내야 한다. 선언된 예외는 둘이다: `bridges`의 `generatedAt`은 실행 시각이고,
`generated-code-staleness` limitation은 mtime 관측이다 — git은 mtime을 보존하지
않으므로 fresh clone 사이에서는 이 문자열의 presence가 달라질 수 있다(내용이 아니라
환경의 관측이며, findings·간선·노드는 영향받지 않는다).

## MCP 서버

`dartograph mcp`는 stdio로 Model Context Protocol(JSON-RPC 2.0) 서버를 띄운다.
AI 클라이언트(Claude Desktop·Cursor·agent 런타임 등)가 dartograph의 분석을 도구
호출로 쓸 수 있다. stdout에는 JSON-RPC만 쓰고 진단은 stderr로 보낸다. 다섯 도구 모두
**읽기 전용**이며 저장소를 수정하지 않는다. 각 도구는 기존 CLI 실행 경로를 그대로
재사용하므로 출력 스키마와 종료 코드가 CLI와 어긋나지 않는다.

| 도구 | 입력 | 답 |
|---|---|---|
| `dartograph_explore` | `packageRoot`(필수) + 질문 형태 하나: `symbol` \| `batch`(심볼 근거+소스), `impactSymbol` \| `since` \| `changed`(영향), `command`(검증·`runtime`) | 인자가 가리키는 도구로 내부 라우팅 — 첫 줄 `routed: <도구>` 표지 뒤 해당 도구와 같은 출력 |
| `impact_query` | `packageRoot`(필수) + `since` \| `changed` \| `symbol` 중 정확히 하나, `depth`, `limit` | `impact --format json` 문서 |
| `dependency_query` | `packageRoot`(필수) + `symbol` \| `batch` 중 정확히 하나, `depth`, `limit`, `baseline`, `withSource`, `sourceContext` | `query`/`query --batch` 문서 |
| `verify_run` | `packageRoot`, `command`(`dead`\|`deps`\|`dup`\|`cycles`\|`rules`\|`metrics`), `strict`, `closedApp`, `minTokens`, `kinds`, `since`, `baseline`, `config`, `format` | `exitCode`와 원시 출력 |
| `runtime_query` | `packageRoot`(필수), `limit` | `runtime --no-verify --format json` 문서 |

도구 결과는 `content: [{type: "text", text}]`로 돌아오고, 텍스트 첫 줄은 항상
`exitCode: <0|1|2|64>`다(`dartograph_explore`는 그 앞에 `routed: <도구>` 줄이 온다).
분석 실패(2)·사용 오류(64)는 `isError: true`다. `format`은
`dead`·`deps`·`dup`에만 적용되고 `cycles`·`rules`·`metrics`는 항상 JSON 질의 문서를 낸다.
`minTokens`는 `dup` 전용, `kinds`는 `dead`·`deps`·`dup` 전용으로 다른 명령에서는 거절한다.
`closedApp`은 `dead`에만 적용된다. 서버 환경 변수 `DARTOGRAPH_MCP_LEGACY_TOOLS=0`
(또는 `false`)이면 `tools/list`가 `dartograph_explore`만 광고한다 — 나머지 도구는
목록에서 빠지지만 호출은 계속 받는다. 서버는 세 가지 정적 리소스(`dartograph://usage`·
`dartograph://skill`·`dartograph://config`)와 네 가지 프롬프트(`impact-precheck`·
`dead-code-review`·`dependency-audit`·`duplication-review`)도 노출한다 — 입력
스키마·예시는 [MCP.md](MCP.md)에 있다.

## VS Code 확장

`editors/vscode/`의 VS Code 확장은 마켓플레이스에 게시돼 있다 — Extensions
뷰에서 **dartograph**를 검색해 설치하고 CLI(`dart pub global activate dartograph`)가
PATH에 있어야 한다. 확장은 설치된 실행 파일을 호출해 JSON 보고서를 **Problems**
진단으로 옮긴다 — 분석기 진단이 아니라 근거·한계를 동반한 그래프 관측이며
삭제 판정은 내리지 않는다.

- `dartograph: Analyze Workspace` — `pubspec.yaml`을 가진 각 워크스페이스 폴더에서
  `dead`·`deps`·`dup`를 실행한다. dead는 선언 위치에 경고로, deps는
  `pubspec.yaml` 첫 줄에, dup는 두 위치의 정보성 범위로 표시한다.
- `dartograph: Check Impact of Current File` — 열린 Dart 파일을
  `impact --changed`의 입력으로 쓰고 영향받는 선언·관련 테스트를 Problems에
  표시한다. risk가 high인 대상만 경고다.
- `dartograph.runOnSave`를 켜면 Dart 파일 저장 직후 디바운스된 재분석이 돈다.
  기본 `dartograph.args`는 `--incremental .dartograph/cache`로 재실행을 빠르게
  유지한다. `dartograph.minTokens`·`dartograph.executable`도 설정으로 조정된다.
- 각 보고서의 `limitations`는 dartograph 출력 채널에 기록한다 — 발견이 없다는
  사실이 안전의 증명이 되지 않는다.

개발 중인 사본은 이 디렉터리를 `~/.vscode/extensions/`에 복사해 시험할 수 있고,
배포용 패키징은 `vsce package`를 쓴다. 자세한 표는
[editors/vscode/README.md](../editors/vscode/README.md)를 본다.

## analysis server 플러그인

`editors/analysis_plugin/`은 `analysis_server_plugin` 프레임워크의 플러그인이다 —
IDE와 `dart analyze` 양쪽에서 그래프 발견을 진단으로 낸다. 프로젝트의
`analysis_options.yaml`에 활성화한다:

```yaml
plugins:
  dartograph_analysis_plugin: ^0.1.0
```

- `dartograph_dead_code`(warning) — `dead` 발견을 선언 위치에 표시한다.
  선언 위 진단에는 `// dartograph:ignore`를 넣는 quick fix가 붙는다.
- `dartograph_duplicate_block`(info) — `dup` 발견을 블록 범위로 표시한다.

플러그인은 PATH의 `dartograph` 실행 파일을 호출한다(`DARTOGRAPH_EXECUTABLE`로
교체 가능). 첫 분석 패스가 보고서를 동기로 적재하고 이후는 TTL 만료 시
백그라운드로 갱신한다 — 증분 캐시(`.dartograph/cache`)가 반복 비용을 줄인다.
진단은 근거 관측이며 삭제 판정이 아니다.

## 종료 코드

| 코드 | 뜻 |
|---:|---|
| 0 | 명령 성공. 일반 보고 모드와 `dead --report-test-only`·`dead --report-redundant-public`(info)는 finding이 있어도 성공 |
| 1 | `dead`·`deps` finding(`--report-test-only`·`--report-redundant-public` 제외), `dead --explain`의 미도달 대상, 또는 `--strict` 분석 명령의 finding |
| 2 | 패키지를 신뢰할 수 있게 분석하지 못함, `--since`·`affected`의 Git 변경 파일을 계산하지 못함(얕은 클론 — CI에서 전체 이력을 fetch한다), 또는 `history`가 원장을 읽지 못함 |
| 64 | 잘못된 명령·인자(`--record`·`history`의 옵션 오류 포함), 또는 `query`/`dead --explain`/`cycles --explain`/`rules --explain` 대상이 그래프에 없음 |

## CI 예제

전체 Git 이력이 있어야 `--since`의 merge-base를 계산할 수 있다.

```yaml
- uses: dart-lang/setup-dart@v1
- run: dart pub global activate dartograph 0.15.1
- run: dartograph dead --format github-actions --since origin/main .
- run: dartograph impact --since origin/main --format github-actions --fail-on high .
```

`dead`는 finding 자체가 코드 1을 반환하므로 `--strict` 인자가 필요하지 않다.
`cycles`, `rules`, `metrics`는 `--strict`를 붙였을 때만 finding을 코드 1로 바꾼다. 세 명령은 `--format <text|json|sarif>`를 받는다(기본 `json` — 플래그가 없으면 기존 출력과 바이트 동일). `text`는 finding을 한 줄씩, `sarif`는 아키텍처 게이트를 code scanning 경고로 낸다. `--explain`(cycles·rules)은 고정 JSON 질의라 `--format json` 외에는 usage 64다.

### SARIF와 GitHub code scanning

다음 명령은 `--format sarif`로 SARIF 2.1.0 문서를 낸다 — `dead`·`deps`·`dup`·`impact`·`runtime`·`cycles`·`rules`·`metrics`·`affected`·`compare`.
결과를 파일로 리다이렉트해 `github/codeql-action/upload-sarif`에 올리면 code scanning 경고로 표시된다.
`cycles`는 순환마다, `rules`는 위반마다, `metrics`는 허용 오차를 넘은 라이브러리와(설정된 경우)
복잡도 상한을 넘은 선언마다 결과를 하나씩 낸다. `affected`는 피영향 라이브러리마다, `compare`는
새로 도달 불가능해진 선언마다 결과를 낸다.

```yaml
permissions:
  security-events: write  # code scanning 업로드에 필요

steps:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 0  # --since의 merge-base 계산에 필요
  - uses: dart-lang/setup-dart@v1
  - run: dart pub get
  - run: dart pub global activate dartograph 0.15.1
  # dead는 finding이 있으면 코드 1이다 — continue-on-error로 업로드 단계까지
  # 도달하게 하고, 경고로 실패시키려면 이 줄을 빼면 된다(아래 참조).
  - id: dead
    continue-on-error: true
    run: dartograph dead --format sarif . > dead.sarif
  - uses: github/codeql-action/upload-sarif@v3
    if: always()
    with:
      sarif_file: dead.sarif
      category: dartograph-dead
```

- `if: always()`는 분석 단계가 코드 1로 실패해도 업로드가 실행되게 한다.
  `continue-on-error`를 빼면 finding이 code scanning 경고 **와** CI 실패 둘 다가 된다.
- 여러 보고를 올릴 때는 `category`를 보고 종류별로 구분한다(예: `dartograph-dead`,
  `dartograph-impact`) — 같은 category·tool로 다시 올리면 code scanning이 이전
  업로드의 결과 전체를 새 run으로 교체하므로, 보고 종류를 나누지 않으면 서로
  다른 분석이 서로를 지운다.
- `artifactLocation.uri`는 **패키지 루트 기준 상대 경로**다. 저장소 루트에서
  실행하면 URI가 저장소 상대 경로와 일치해 code scanning이 파일을 바로 연다.
  하위 디렉터리에서 실행하면 그 하위 경로 기준 URI가 되므로 `working-directory`를
  저장소 루트로 맞추거나 경로를 조정한다.
- 물리 위치가 없는 결과는 SARIF에 들어가지 않는다 — `impact`의 `project:` 소스가
  없는 피영향 심볼(`package:` URI id)은 제외되고 그 수가
  `invocations[].properties.resultsWithoutLocation`에 남는다. 파일 수준 `dead`
  finding은 위치는 있지만 `region`이 없다(발명된 1:1 위치를 만들지 않는다).
- 실행 한계·억제 수는 결과가 아니라 `invocations[].properties`에 실린다 —
  `limitations`·`suppressedCount`(dead), `coverage`·`risk`(impact)를 code scanning
  결과 목록에서 찾지 말고 원본 파일에서 확인한다.
- 위 예시의 액션 핀은 작성 시점 기준이며, 액션 버전은 저장소 정책에 맞춰 갱신한다.

## 분석 한계

- 조건부 import/export는 공개 analyzer가 고른 단일 구성만 분석한다.
- 동적 디스패치, 문자열 route, 네이티브 진입점은 정적 그래프가 완전히 증명하지 못한다.
- 생성 파일은 보수적으로 보존하며 오래된 산출물을 한계로 보고한다.
- enum이 도달 가능하면 그 상수도 보존한다. `.values`·switch·직렬화처럼 개별 상수를 직접
  참조하지 않는 소비가 있으므로 enum→상수 `member` 간선만으로 미도달이라고 단정하지 않는다.
  `dead --explain`은 `retained by its reachable enum` 근거와 enum까지의 경로를 낸다.
- `main` 진입점은 여러 개일 수 있다. 기본적으로 `lib/`, `bin/`, `example/`의 모든 `main`을 보수적으로 보존하므로 분석 전에 실제 build target을 확인한다. 실제 build target을 `dartograph.yaml`의 `entry_points`로 선언하면 그 파일의 `main`만 보존 루트로 좁힌다. 설정하지 않거나 키가 없으면 기본 보수 정책을 유지한다(템플릿은 `dartograph init`으로 생성할 수 있다).

`<package-root>`는 하나의 패키지다. pub 워크스페이스(루트 pubspec의 `workspace:`
멤버 목록과 멤버의 `resolution: workspace`)에서는 **멤버 루트를 직접** 지정한다.
멤버는 자체 `.dart_tool/package_config.json`을 두지 않고 워크스페이스 루트의 것을
공유하므로 루트에서 `dart pub get`을 한 번 실행하면 되고, 형제 멤버는 `project:`
소스가 아니라 `package:` 의존으로 보인다 — 단일 패키지 경계는 일반 패키지와 같다.
워크스페이스 루트를 직접 지정하면 루트 자신의 패키지 소스만 분석되고 선언된 멤버는
분석 대상 디렉터리 밖이라 `workspace-members-not-indexed` 한계로 나열된다 —
멤버 소스를 조용히 빠뜨리지 않고, 멤버별로 따로 실행한다는 뜻이다.

```yaml
# dartograph.yaml (프로젝트 루트, 선택)
entry_points:
  - lib/main.dart
  - lib/main_production.dart
```

`entry_points`는 `lib/`, `bin/`, `example/` 아래에 실제로 존재하는 `.dart` 파일의 프로젝트 상대 경로 목록이어야 하며 비어 있을 수 없다. 절대 경로·루트 밖(`..`) 경로·비문자열 항목·범위 밖 디렉터리·존재하지 않는 파일·`.dart`가 아닌 항목은 조용히 무시하지 않고 분석 실패(종료 코드 2)로 알린다. 이는 잘못된 설정으로 사용자가 선언한 build target이 무시되거나 보존 루트가 잘못 좁혀져 삭제 오탐으로 이어지는 것을 막기 위해서다. 존재하지만 `main`이 없는 진입점은 `configured-entry-point-without-main` 한계로 보고한다. `entry_points`가 선언되면 보존이 좁혀졌다는 사실 자체도 `entry-points: main retention roots narrowed to N declared build target(s)` 한계로 모든 보고에 실린다 — 설정 추가만으로 죽은 코드가 출력상 조용히 사라지지 않는다. 이 설정은 보존 루트 의미이므로 해석 캐시 키에 포함되며 캐시 identity를 올려 기본 정책으로 분석한 결과를 재사용하지 않는다.

로컬 path dependency의 generated Pigeon/Dart source를 그래프에 포함해야 하면 같은 파일에
`source_packages`를 명시한다.

```yaml
source_packages:
  - vendor/shared_preferences_android
```

각 항목은 프로젝트 안의 중첩 package root여야 하며 `pubspec.yaml`과 `lib/`를 가져야 한다.
기본 분석 범위는 바뀌지 않고, 설정한 package의 `lib/`만 추가된다. 절대·루트 밖 경로,
심볼릭 링크, `.dart_tool`·`build`·`.fvm` 경로, 중복 package는 조용히 무시하지 않고 분석
실패(종료 코드 2)로 알린다. package config가 제공한 `package:` URI와 analyzer element
identity를 그대로 사용하며, package source와 이 설정은 분석 캐시 키에 포함된다.

같은 파일의 나머지 키는 보고 범위·보존·임계를 조정한다.

```yaml
# dead·deps·dup 발견 보고 범위(gitignore류 glob, 소스 ID의
# project:/package: 스킴을 뗀 경로에 매칭). 그래프 자체는 바뀌지 않는다.
include:
  - lib/**
exclude:
  - lib/generated/**

# `// dartograph:ignore`의 설정 파일 판. retained_names는 선언 이름
# (`Class.member` 포함), retained_files는 맞은 파일의 모든 선언을 보존한다.
retained_names:
  - '*.fromJson'
retained_files:
  - lib/gen/**

# metrics --strict의 게이트다.
thresholds:
  distance: 0.3     # |D'| 허용치(기본 0.3)
  complexity: 40    # 선언 순환 복잡도 상한
```

- `include`가 있으면 맞는 소스만 발견을 내고, `exclude`는 맞는 소스의 발견을 뺀다.
  deps의 소스 근거도 같은 범위로 좁혀지며 근거가 전부 빠진 발견은 관측이 사라진
  것으로 본다. dup 발견은 범위 밖 인스턴스를 걸러 위치가 둘 미만이면 내지 않는다.
  범위 좁힘이 활성이면 `include-exclude:` 한계가 보고에 실린다.
- `retained_*`로 늘어난 보존 루트는 `configuredRetention` 사유를 갖고
  `retention-config:` 한계로 집계된다. 이 키들은 분석 의미를 바꾸므로 캐시
  identity에 포함된다.
- 모르는 최상위 키는 `config-unknown-keys:` 한계로 보고한다 — 오타가 조용히
  무시되지 않는다. 비어 있는 목록·비문자열 항목·잘못된 thresholds 타입·모르는
  thresholds 키는 분석 실패(종료 코드 2)다.
- finding은 검토할 후보와 근거이며 삭제 지시가 아니다.
- `source-analysis-errors`, `source-unresolved-invocations`, `source-conditional-configuration`은
  관측된 **파일**의 finding에 붙는다. 특정 선언이 원인이라고 단정하지 않는다.
  다른 파일에 관측된 동적 호출도 해당 선언을 사용할 수 있으므로 전역 경고도 유지한다.
  한계 목록이 비어 있어도 분석의 완전성이나 안전한 삭제를 보증하지 않는다.
- `bridges`는 Flutter services의 직접 import만 채널 provenance로 사용한다. re-export
  barrel을 거친 사용은 추측해 연결하지 않고 `flutter-services-reexports` limitation으로
  보고한다.
- `bridges`는 `MethodChannel('')`처럼 빈 채널·메서드 이름을 그 사실만 건너뛰고
  `empty-bridge-names` limitation으로 집계한다. 한 줄의 빈 이름이 나머지 사실을 가리지
  않는다. 제어 문자가 든 이름·소스 경로는 계속 분석 실패(종료 코드 2)로 전면 거부한다(0.3.0부터의 동작 — 실패 원인은 "Bridges extraction failed" 진단으로 귀속된다).

분석 캐시는 대상 저장소 밖의 OS 사용자 캐시 아래 `dartograph/<project-root-hash>`에
저장된다. 삭제해도 안전하며 다음 실행에서 다시 만들어진다. 캐시를 읽거나 쓸 수 없으면
analyzer를 직접 실행한다. 대상 패키지뿐 아니라 package config가 가리키는 path/git/hosted
의존 패키지의 `lib/` 내용도 키에 포함한다.

미도달 finding이 확인한 보존 루트가 20개보다 많으면 `evidence`에는
`retentionRootCount`, 결정적 앞 20개 `retentionRootsChecked`,
`retentionRootsTruncated: true`가 들어간다. 대형 프로젝트에서 같은 전체 루트 목록을 모든
finding에 반복하지 않기 위한 출력 계약이다.

## 에이전트 평가와 교차 언어 근거

`dart test test/index/evidence_mutation_test.dart`는 호출 제거·복원, 이름 변경,
미해석 호출과 소스별 한계 분리를 실제 analyzer로 검사한다.
`dart run tool/benchmark_query.dart`는 2,000개 노드/100개 요청의 개별·공유 세션
결과가 같은지 확인하고 시간을 출력한다. 합성 측정이며 실제 프로젝트 SLA가 아니다.

`bridges`의 MethodChannel fact에는 지원되는 Dart 함수/메서드의
`symbol.qualifiedName`을 함께 실어 isthmus query의 Dart→Swift 양쪽 근거에 보존한다.
이 값은 어휘적 이름이며 컴파일러 USR을 만들지 않는다. 생성자·extension 등 이름 귀속을
지원하지 않는 호출도 위치는 유지하며 `missing-caller-symbols` 한계를 표시한다.
실제 매칭·동적 이름·복수 후보 처리는 기존 isthmus 계약을 따른다.

```bash
isthmus query takePhoto dart-bridges.json swift-bridges.json
dart run tool/verify_bridge_query.dart /path/to/isthmus/dist/cli/main.js
```

왕복 검증 스크립트는 실제 Dart 추출과 합성 Swift fact를 사용한다. Swift 컴파일러 검증을
대체하지 않으며, isthmus가 이미 설치된 환경에서 실행한다.

# 설치와 사용

## 설치

dartograph 0.11.0은 Dart SDK 3.11 이상에서 동작하는 순수 Dart 패키지다.

```bash
dart pub global activate dartograph
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
dartograph graph --format <dot|json|mermaid|html|anon> [--level <file|type|symbol>] [--collapse <n>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph dead --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--baseline <file>] [--since <ref>] [--closed-app] [--incremental <dir>] [--record <dir>] <package-root>
dartograph dead --explain <symbol-id> --format json [--incremental <dir>] [--record <dir>] <package-root>
dartograph dead --report-test-only --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--since <ref>] [--closed-app] [--incremental <dir>] [--record <dir>] <package-root>
dartograph dead --report-redundant-public --format <text|json|markdown|codeowners|github-actions|sarif> [--codeowners <file>] [--since <ref>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph deps [--format <text|json|markdown|github-actions|sarif>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph baseline --write <file> [--closed-app] [--incremental <dir>] [--record <dir>] <package-root>
dartograph query <symbol-id-or-name> [--baseline <file>] [--depth <n>] [--limit <n>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph query --batch <requests.json> [--baseline <file>] [--depth <n>] [--limit <n>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph compare [--incremental <dir>] [--record <dir>] <before-package-root> <after-package-root>
dartograph affected [--incremental <dir>] [--record <dir>] <git-ref> <package-root>
dartograph impact --since <git-ref> [--format <text|json|markdown|github-actions|sarif>] [--depth <n>] [--limit <n>] [--fail-on <none|low|medium|high>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph impact --changed <changes.json> [--format <fmt>] [--depth <n>] [--limit <n>] [--fail-on <level>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph impact --symbol <symbol-id> [--format <fmt>] [--depth <n>] [--limit <n>] [--incremental <dir>] [--record <dir>] <package-root>
dartograph skill [--install <skills-directory> [--force]]
dartograph runtime [--verify|--no-verify] [--format <text|json|markdown|github-actions|sarif>] [--dart-define KEY=VALUE]... [--env KEY=VALUE]... [--limit <n>] [--fail-on <none|low|medium|high>] [--execute <dart-entrypoint>] [--record <dir>] <package-root>
dartograph history --ledger <dir> [--commit <sha>] [--format <text|json>]
dartograph mcp
dartograph bridges --format json [--project <shared-root>] <package-root>
dartograph bridges --messages --format json [--project <shared-root>] <package-root>
dartograph cycles [--strict] [--incremental <dir>] [--record <dir>] <package-root>
dartograph cycles --explain <symbol-id> [--incremental <dir>] [--record <dir>] <package-root>
dartograph rules --config <yaml-file> [--strict] [--incremental <dir>] [--record <dir>] <package-root>
dartograph rules --config <yaml-file> --explain <symbol-id> [--incremental <dir>] [--record <dir>] <package-root>
dartograph metrics [--strict] [--incremental <dir>] [--record <dir>] <package-root>
```

`--incremental <dir>`는 분석·색인 명령(graph·dead·deps·query·compare·affected·
impact·baseline·cycles·rules·metrics)이 받는다. 디렉터리에 파일별 사실 캐시를 두고 다음
실행에서 바뀐 파일과 그 파일을 import·export하는 폐쇄만 다시 해석한다. 산출물은
전체 해석과 byte 동일하다. 캐시가 없거나 손상됐거나 스키마가 다르거나 쓸 수 없으면
전체 해석으로 폴백하고 오류로 끝내지 않는다(쓸 수 없을 때만 그 사실을 limitation으로
남긴다). 캐시 디렉터리는 프로젝트마다 따로 쓴다. 널리 import되는 파일을 바꾸면
폐쇄가 사실상 전체에 가까워 이득이 줄어든다(변경 없음·잎 파일 변경에서는 크다).

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

사용은 **관측**으로만 판정한다 — `package:` 지시문이 없어도 도구 계약이 요구하는
의존은 사용으로 친다: pubspec `executables`에 노출된 실행 파일, `build.yaml`의
`builders`·`post_process_builders`, `analysis_options.yaml`이 include하거나
analyzer plugin으로 올린 패키지. 이 근거는 finding의 `evidence`와 보고서의
`tool-usage:` limitation에 실린다. 런타임 로딩(`Isolate.spawnUri` 등), 생성 코드가
import하는 패키지, 에셋 경로만의 참조는 이 감사에 보이지 않으며 그 사실이 limitation으로
남는다. `dependency_overrides`는 사용 관측을 만들지 않으므로 미사용으로 보고하지
않는다. finding이 있으면 종료 코드 1이다 — 삭제 지시가 아니라 검토 목록이다.

`query`는 일치한 심볼의 양방향 관계, 멤버, 보존 경로, baseline 상태를 답한다. 찾지 못한
경우에도 `notFound`와 `limitations`를 함께 낸다. 기본 `bridges`는 Flutter MethodChannel
채널·메서드 사실을 GRAPH-EXCHANGE v1 JSON으로 낸다. `bridges --messages`는 개발 소스
전용 opt-in 경로로, 실제 BasicMessageChannel `send` 호출만 bridge-facts v2
(`transport: basic-message-channel`, `kind: message-send`)로 낸다. 채널 생성은 send로
세지 않으며 MethodChannel의 method 필드도 만들지 않는다. 동적 이름은 원래 표현식을
보존하고, `channelPrefix`는 AST가 증명한 decoded 비어 있지 않은 문자열 interpolation
선행 literal일 때만 후보 근거로 낸다. prefix는 완전한 runtime 주소·instance identity의
증명이 아니며, 이 경로는 0.9.0에 새로 추가되었다. 패키지의
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
PATH의 Dart SDK로 `dart run <entrypoint>`를 띄우고 `--env` 값을 상속 환경 위에 덮어쓴 뒤
종료 코드와 stderr 요약(4 KiB 상한)을 실행 증거로 남긴다. 실행 실패는 위험 요인
(`execution-failed`, 30)이 되지만 나머지 보고는 그대로 나온다. 경로처럼 보이는 인자
(`.dart`로 끝나거나 경로 구분자를 포함)는 파일 존재를 요구하며 없으면 usage(64)다 —
패키지 실행 파일 이름은 `dart run`이 해석하므로 존재를 요구하지 않는다. 신뢰한
프로젝트에서만 쓴다. 실행과 출력 수집에는 합쳐서 60초 제한을 적용하고, 제한을 넘으면
직접 실행한 자식의 종료를 최대 5초 더 확인한다. 부모가 종료돼도 후손이 출력 파이프를
보유하면 `timedOut`으로 보고하며 파이프 수집을 중단한다. 후손 프로세스 전체를 종료하는
격리 기능은 제공하지 않는다. AOT 설치본도 `--execute`에는 PATH의 Dart SDK가 필요하다.

`--format`은 `text`(기본)·`json`·`markdown`·`github-actions`·`sarif`다. 사람은 `text`·
`markdown`, CI는 `github-actions`(`missing` 항목은 위험이 `high`면 `error`, 아니면
`warning`)·`sarif`를 쓴다. `--limit <n>`은 **보고** 항목 수 상한이다(탐지·판정·위험도는
제한하지 않는다 — `--limit`이 종료 코드를 바꾸면 게이트가 아니다). 생략한 수는 목록별로
`truncated`에 남는다. `--fail-on <level>`은 위험 등급이 그 수준 이상이면 종료 코드 1로
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
호출로 쓸 수 있다. stdout에는 JSON-RPC만 쓰고 진단은 stderr로 보낸다. 세 도구 모두
**읽기 전용**이며 저장소를 수정하지 않는다. 각 도구는 기존 CLI 실행 경로를 그대로
재사용하므로 출력 스키마와 종료 코드가 CLI와 어긋나지 않는다.

| 도구 | 입력 | 답 |
|---|---|---|
| `impact_query` | `packageRoot`(필수) + `since` \| `changed` \| `symbol` 중 정확히 하나, `depth`, `limit` | `impact --format json` 문서 |
| `dependency_query` | `packageRoot`(필수) + `symbol` \| `batch` 중 정확히 하나, `depth`, `limit`, `baseline` | `query`/`query --batch` 문서 |
| `verify_run` | `packageRoot`, `command`(`dead`\|`deps`\|`cycles`\|`rules`\|`metrics`), `strict`, `closedApp`, `since`, `baseline`, `config`, `format` | `exitCode`와 원시 출력 |

도구 결과는 `content: [{type: "text", text}]`로 돌아오고, 텍스트 첫 줄은 항상
`exitCode: <0|1|2|64>`다. 분석 실패(2)·사용 오류(64)는 `isError: true`다. `format`은
`dead`·`deps`에만 적용되고 `cycles`·`rules`·`metrics`는 항상 JSON 질의 문서를 낸다.
`closedApp`은 `dead`에만 적용된다. 서버는 세 가지 정적 리소스(`dartograph://usage`·
`dartograph://skill`·`dartograph://config`)와 세 가지 프롬프트(`impact-precheck`·
`dead-code-review`·`dependency-audit`)도 노출한다 — 입력 스키마·예시는
[MCP.md](MCP.md)에 있다.

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
- run: dart pub global activate dartograph 0.11.0
- run: dartograph dead --format github-actions --since origin/main .
- run: dartograph impact --since origin/main --format github-actions --fail-on high .
```

`dead`는 finding 자체가 코드 1을 반환하므로 `--strict` 인자가 필요하지 않다.
`cycles`, `rules`, `metrics`는 `--strict`를 붙였을 때만 finding을 코드 1로 바꾼다.

## 분석 한계

- 조건부 import/export는 공개 analyzer가 고른 단일 구성만 분석한다.
- 동적 디스패치, 문자열 route, 네이티브 진입점은 정적 그래프가 완전히 증명하지 못한다.
- 생성 파일은 보수적으로 보존하며 오래된 산출물을 한계로 보고한다.
- enum이 도달 가능하면 그 상수도 보존한다. `.values`·switch·직렬화처럼 개별 상수를 직접
  참조하지 않는 소비가 있으므로 enum→상수 `member` 간선만으로 미도달이라고 단정하지 않는다.
  `dead --explain`은 `retained by its reachable enum` 근거와 enum까지의 경로를 낸다.
- `main` 진입점은 여러 개일 수 있다. 기본적으로 `lib/`, `bin/`, `example/`의 모든 `main`을 보수적으로 보존하므로 분석 전에 실제 build target을 확인한다. 실제 build target을 `dartograph.yaml`의 `entry_points`로 선언하면 그 파일의 `main`만 보존 루트로 좁힌다. 설정하지 않거나 키가 없으면 기본 보수 정책을 유지한다(템플릿은 `dartograph init`으로 생성할 수 있다).

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

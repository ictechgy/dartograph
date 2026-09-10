# 설치와 사용

## 설치

dartograph 0.6.0은 Dart SDK 3.11 이상에서 동작하는 순수 Dart 패키지다.

```bash
dart pub global activate dartograph
dartograph --version
```

저장소 소스에서 실행할 때는 `dartograph` 대신 `dart run dartograph`를 쓴다.

## 명령

```text
dartograph graph --format <dot|json|mermaid|html|anon> [--level <file|type|symbol>] [--collapse <n>] <package-root>
dartograph dead --format <text|json|github-actions|sarif> [--baseline <file>] [--since <ref>] <package-root>
dartograph dead --explain <symbol-id> --format json <package-root>
dartograph dead --report-test-only --format <text|json|github-actions|sarif> [--since <ref>] <package-root>
dartograph baseline --write <file> <package-root>
dartograph query <symbol-id-or-name> [--baseline <file>] [--depth <n>] [--limit <n>] <package-root>
dartograph query --batch <requests.json> [--baseline <file>] [--depth <n>] [--limit <n>] <package-root>
dartograph compare <before-package-root> <after-package-root>
dartograph affected <git-ref> <package-root>
dartograph skill [--install <skills-directory> [--force]]
dartograph bridges --format json [--project <shared-root>] <package-root>
dartograph cycles [--strict] <package-root>
dartograph cycles --explain <symbol-id> <package-root>
dartograph rules --config <yaml-file> [--strict] <package-root>
dartograph rules --config <yaml-file> --explain <symbol-id> <package-root>
dartograph metrics [--strict] <package-root>
```

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
`--explain`은 도달 경로나 미도달 근거를 JSON으로 낸다. `baseline`은 현재 finding을 기록하고,
`--since`는 전체 그래프를 만든 뒤 Git 기준 ref 이후 바뀐 파일로 보고 범위를 좁힌다.
심볼릭 링크 소스는 양방향으로 매치된다 — 링크 파일 자체가 바뀐 경우(링크 경로)와
링크 대상이 바뀐 경우(해석된 실 경로) 모두 변경 집합에 속한다.
`--explain`은 단일 대상의 전체 근거를 묻는 명령이라 `--baseline`·`--since`와 함께 쓰지 않는다.
그래프에 없는 ID는 `known: false`와 종료 코드 64로 구분한다.

`dead --report-test-only`는 다른 질문을 답한다: 테스트 디렉터리(`test/`·`integration_test/`
등)의 보존 루트를 빼고 다시 도달성을 계산해, **프로덕션 선언인데 테스트에서만 도달되는**
것을 고른다. 이들은 죽은 코드가 아니라(삭제하면 테스트가 깨진다) "테스트가 유일한 호출자"
라는 관측이므로 `info` 심각도로 보고되고 **finding이 있어도 종료 코드 0**이다(빌드를 실패
시키지 않는다). 테스트 디렉터리 내부 선언과 `@visibleForTesting` 프로덕션 선언(테스트
디렉터리 밖이라 루트로 남음)은 보수적으로 답에서 제외한다. 단일 대상 질의인 `--explain`,
dead finding을 억제하는 `--baseline`과는 결합하지 않으며 `--since`·`--format`은 허용한다.

`query`는 일치한 심볼의 양방향 관계, 멤버, 보존 경로, baseline 상태를 답한다. 찾지 못한
경우에도 `notFound`와 `limitations`를 함께 낸다. `bridges`는 Flutter 채널 사실을
GRAPH-EXCHANGE v1 JSON으로 낸다. 패키지의 `lib/<package-name>.dart`가 export한 공개 선언과
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

`rules --config`의 layers.yaml 스키마는 엄격하다. `layers`는 `name`과 `match`(정점 ID와
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

## 종료 코드

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

| 코드 | 뜻 |
|---:|---|
| 0 | 명령 성공. 일반 보고 모드와 `dead --report-test-only`(info)는 finding이 있어도 성공 |
| 1 | `dead` finding(`--report-test-only` 제외), 또는 `--strict` 분석 명령의 finding |
| 2 | 패키지를 신뢰할 수 있게 분석하지 못함 |
| 64 | 잘못된 명령·인자, 또는 `query`/`dead --explain`/`cycles --explain`/`rules --explain` 대상이 그래프에 없음 |

## CI 예제

전체 Git 이력이 있어야 `--since`의 merge-base를 계산할 수 있다.

```yaml
- uses: dart-lang/setup-dart@v1
- run: dart pub global activate dartograph 0.6.0
- run: dartograph dead --format github-actions --since origin/main .
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
- `main` 진입점은 여러 개일 수 있다. 기본적으로 `lib/`, `bin/`, `example/`의 모든 `main`을 보수적으로 보존하므로 분석 전에 실제 build target을 확인한다. 실제 build target을 `dartograph.yaml`의 `entry_points`로 선언하면 그 파일의 `main`만 보존 루트로 좁힌다. 설정하지 않거나 키가 없으면 기본 보수 정책을 유지한다.

```yaml
# dartograph.yaml (프로젝트 루트, 선택)
entry_points:
  - lib/main.dart
  - lib/main_production.dart
```

`entry_points`는 `lib/`, `bin/`, `example/` 아래에 실제로 존재하는 `.dart` 파일의 프로젝트 상대 경로 목록이어야 하며 비어 있을 수 없다. 절대 경로·루트 밖(`..`) 경로·비문자열 항목·범위 밖 디렉터리·존재하지 않는 파일·`.dart`가 아닌 항목은 조용히 무시하지 않고 분석 실패(종료 코드 2)로 알린다. 이는 잘못된 설정으로 사용자가 선언한 build target이 무시되거나 보존 루트가 잘못 좁혀져 삭제 오탐으로 이어지는 것을 막기 위해서다. 존재하지만 `main`이 없는 진입점은 `configured-entry-point-without-main` 한계로 보고한다. `entry_points`가 선언되면 보존이 좁혀졌다는 사실 자체도 `entry-points: main retention roots narrowed to N declared build target(s)` 한계로 모든 보고에 실린다 — 설정 추가만으로 죽은 코드가 출력상 조용히 사라지지 않는다. 이 설정은 보존 루트 의미이므로 해석 캐시 키에 포함되며 캐시 identity를 올려 기본 정책으로 분석한 결과를 재사용하지 않는다.
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

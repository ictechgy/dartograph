# Handoff

_Last updated: 2026-11-28 (6차: `unresolved-files:` 한계, `--workspace` 중첩 멤버 한계, impact-precheck 실패 조사)_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다(PR #166 시점 원문은 그 파일 끝 절).

## Current Status

- 발행본은 **0.17.0**이다(pub.dev, GitHub Release `v0.17.0`, `dartograph_analysis_plugin` 0.1.1).
  `main`의 `Unreleased`에는 PR #161(`4bd0370`), #163(`88dd0ee`), #164(`7da8267`), #165(`acda403`),
  #166(`28d75c7`, workspace 멤버 파일 finding 경로·멤버별 `public-libraries:`·rules 진단 길이)이
  있다. 아직 발행하지 않았다.
- 브랜치 `ccr-37904670-hxdjsx`를 `origin/main` `28d75c7`에서 다시 시작했다(이전 PR은 스쿼시 머지).
  푸시·PR은 코디네이터가 한다. 어느 커밋까지 푸시됐는지와 CI 상태는 이 문서에 적지 않는다.
  - 커밋: `3ab920c`(unresolved-files), `02d48d1`(중첩 멤버), `e81dc69`(unresolved-files 문구에
    `#`·`?`), `055cfa3`(중첩 멤버의 글롭 항목), `e36ee10`(3.11 lint에 맞춘 반복문), `d839b9e`(HANDOFF·README,
    여기까지 PR #167로 푸시됨). 그 위에 PR #167 독립 리뷰 반영: `dd27ec7`(unresolved-files 문구에 백슬래시),
    `856fdd7`(중첩 멤버 글롭 펼치기·깊은 중첩·안내 문구), `b3eab8f`(경로 셋으로 묶기·깊이 상한 줄),
    `9502e05`(맞는 것 없는 글롭·깊이 상한 테스트), 그 뒤 문서 커밋. 리뷰 반영분은 푸시하지 않았다.

## 이번 브랜치의 변경

두 수정 모두 `origin/main`을 네이티브 바이너리(`dg-main`)로 컴파일해 먼저 재현했고, 수정본
바이너리와 바이트 단위로 비교했다. 둘 다 한계 줄만 더한다. 그래프·finding·종료 코드는 그대로다.

### 1. analyzer가 해석하지 않은 파일: `unresolved-files:` 한계

- 재현(이전 HANDOFF 후속 항목): 패키지 `lib/src/dead%20enc.dart`, `lib/src/dead%25.dart`는
  `dead`·`graph` 어디에도 없고 한계도 없었다. 더 나쁜 모양: 공개 라이브러리가
  `import 'src/enc%2520x.dart'`로 그 파일의 `EncUsed`를 쓰고 `EncUsed.run`만
  `helper.dart`의 `helperOnlyFromEnc`를 부르면 `dart analyze`는 깨끗한데 `dg-main dead`는
  `helperOnlyFromEnc`와 `helper.dart`를 미도달로 보고하고(종료 1) 이유를 알리지 않았다. 파일
  이름을 `enc_x.dart`로 바꾸면 그 두 finding은 사라지고 `EncDead`만 남는다.
- 원인: analyzer(검증 집합 14.3~14.7의 코드가 같다)는 `getResolvedUnit(path)`에서
  `FileSystemState.hasUri`로 경로→URI→경로 왕복을 확인하고, 실패하면 `NotPathOfUriResult`를
  준다. `PackageMapUriResolver.pathToUri`가 패키지 `lib/` 아래 경로를 이스케이프 없이
  `package:` URI로 만들어(`uriCache.parse('package:$name/$relPath')`) 유효한 `%XX`는 다른 문자로
  디코딩되고, `#`·`?`는 fragment·query가 되며, `\`는 `Uri.parse`가 `/`로 읽는다. `_resolveUnitFacts`는
  그 결과를 null로 받아 조용히
  건너뛰었다. `bin/`·`test/`의 `file:` URI, `%zz` 같은 무효 이스케이프, `+`·`[]`·한글 이름은 왕복한다
  (직접 확인).
- 수정: 열거한 분석 대상 중 사실이 없는 파일을 `_unresolvedFiles`로 전체·증분 경로가 같은 함수로
  세어 `options-excluded-files:`와 같은 모양(수, 경로순 앞의 셋, `and N more`)으로 싣는다. 캐시 신원
  v39(이후 이 브랜치에서 v41까지 올림). analysis options가 제외한 파일은 열거 단계에서 빠져
  `options-excluded-files:`에만 든다.
- 이 한계를 싣는 것은 그래프를 만드는 명령(`dead`·`query`·`impact`·`graph`·`cycles`·`metrics`·
  `deps` 확인)이다. `runtime`·`routes`·`bridges`·`schema`는 그래프 밖에서 유닛을 따로 해석하며
  (`resolveProjectUnitsEach` 등) 같은 파일을 여전히 조용히 건너뛴다(아래 "남긴 것").
- 테스트: `test/index/unresolved_files_test.dart` 3개(실제 analyzer: 6개 파일 수와 앞의 셋, 대조군
  `%zz`·`bin/`이 그래프에 있음, 퍼센트 파일만 지우면 줄 없음, 증분 첫 실행·재사용·파일 변경 뒤 같은 줄).
  `origin/main`·`d839b9e` 코드에서 첫째·셋째가 실패하고, 증분 경로에만 빈 목록을 넘기는 변형이 셋째를
  실패시킨다.

### 2. `--workspace`의 중첩 워크스페이스 멤버

- 재현(이전 HANDOFF 후속 항목): 루트 `workspace: [pkgs/nest]`, `pkgs/nest/pubspec.yaml`이
  `workspace: [sub]`를 선언(Dart 3.13.3 `dart pub get --offline`이 받아들이고 package config에 `sub`가
  든다). `dg-main dead --workspace`는 `workspace-members-indexed: pkgs/nest …`와 `0 finding(s)`로 끝나고
  `sub/lib/orphan.dart`의 `SubOrphan`은 그래프에 없었다.
- 수정(최종, `856fdd7`·`b3eab8f`): 집계한 멤버에서 시작해 선언된 중첩 멤버의 pubspec을 다시 따라가며
  (방문 집합, 깊이 상한 32) 선언한 패키지마다 `workspace-members-not-indexed: pkgs/nest/sub are nested
  workspace members declared by pkgs/nest; --workspace aggregates only the members listed in the root
  pubspec; run dartograph on each member root`을 싣는다. 경로는 앞의 셋과 나머지 수(`… and N more`)다.
  - 글롭(pub은 언어 버전 3.11부터 받는다): `*`·`?`만 쓰는 항목은 `pubspec.yaml`이 있는 디렉터리에
    마디마다 맞춰 펼치고(마디 수만큼만 내려감, 링크는 따라감, O(이름×패턴) 매처) 맞은 디렉터리마다
    판정한다. `**`·`[...]`·`{...}`·`\`가 든 글롭, 맞는 디렉터리가 없거나 읽지 못한 디렉터리가 있는 글롭은
    `… are workspace member globs declared by … that dartograph does not expand; …` 줄에 패턴으로 센다.
    패키지 `glob`의 정규식 매처는 저장소가 고른 패턴의 역추적 비용 때문에 쓰지 않았다(새 의존성도 없음).
  - pub 동작(3.13.3에서 확인): `pubspec.yaml`이 있는 디렉터리만 고르고, 숨김 디렉터리도 고르며, `**`는
    재귀하고, 맞는 것이 없거나 고른 패키지에 `resolution: workspace`가 없으면 `pub get`이 실패한다.
    dartograph는 숨김 디렉터리를 고르지 않는다 — 분석 캐시 키가 숨김 디렉터리의 pubspec을 해시하지 않아,
    골랐다면 캐시 적중이 낡은 줄을 낸다(숨김만 맞는 글롭은 맞는 것이 없어 패턴으로 센다).
  - 세지 않는 것: 루트 목록으로 이미 집계한 멤버, 그리고 그 디렉터리 안에 (더 안쪽 집계 멤버의 것이 아닌)
    분석 대상 파일이 있는 디렉터리(멤버의 표준 소스 디렉터리 안 `pkgs/nest/example`은 통째로 분석된다.
    `source_packages` 패키지는 `lib/`만 분석되고 `test/` 등은 분석되지 않는다 — 그 패키지의 줄은 없고,
    이것은 `source_packages`의 기존 계약이다). Dart 파일이 없는 중첩 멤버는 센다.
  - pub이 거부하는 항목(절대 경로, `..`)은 출력하지 않는다(루트 해석처럼 스캔 루트 밖을 반향하지 않는다).
    링크를 거친 pubspec과 숨김 디렉터리의 pubspec은 따라가지 않는다(`loop -> .` 링크에서 한 줄로 끝남을
    확인). 32단계를 넘어 다시 멤버를 선언하는 패키지는 `the workspace members declared by … were not
    followed (nesting deeper than 32 levels)` 줄에 적는다(35단계 사슬에서 확인).
  - `--workspace` 없는 출력은 그대로다. `runtime --workspace`는 이 줄을 싣지 않는다. 캐시 신원 v41
    (v40은 `dd27ec7`의 백슬래시 문구). 키는 이미 숨김 아닌 모든 pubspec을 해시한다. 글롭이 고르는
    패키지를 더한 뒤 캐시 경로·증분 경로가 새로 분석한 결과와 같음을 확인했다.
  - 거쳐 온 길: `02d48d1`은 집계한 멤버의 항목만 보고 "run dartograph --workspace on pkgs/nest"를
    안내했고, `055cfa3`은 글롭을 첫 글롭 마디 앞 디렉터리로만 판정했다. PR #167 독립 리뷰(아래)가 그
    빈틈과 실패하는 안내를 찾았다.
- 테스트: `test/index/nested_workspace_members_test.dart` 6개.
  - 첫 fixture(pub이 받아들임): `sub`(안쪽 `sub/inner`만 루트가 나열)·`example`·`empty`를 선언한
    `pkgs/nest`. 기대 줄은 `empty, sub`이다. `--workspace` 없는 줄은 그대로이고, `pkgs/nest`를 루트로
    집계하면 줄이 없고, 증분 경로도 같은 줄이다.
  - 글롭·깊은 중첩 fixture(언어 3.11, pub이 받아들임): `sub_*`(→ sub_x, sub_y), `*`(→ q1~q4는 `and 1
    more`로 세고, 이미 분석되는 example은 세지 않음), `packages/*`(p1은 `source_packages`라 빼고 p2만),
    `{m1,m2}`(패턴 줄), `sub`가 다시 `deeper` 선언(두 줄)을 확인한다.
  - 손으로 쓴 package config fixture(pub이 거부): 맞는 것 없는 `nothing_*`(패턴 줄), 별 뒤 0자로 맞는
    `sub*`, 33단계 사슬(32줄과 `were not followed` 줄).
  - `d839b9e` 코드에서 첫째·넷째·다섯째·여섯째가 실패한다. 변형 여덟이 각각 실패시킨다: 재귀 빼기,
    와일드카드를 글자 그대로 보기, 분석 확인 빼기, 펼치지 못한 글롭 버리기, 맞는 것 없는 글롭 버리기, 셋으로
    묶기 빼기, 따라가지 않은 패키지 세지 않기, 옛 안내 문구.

### 적대 입력 (`dg-main` → 수정본, `dead --format json`)

- 1: part 파일(`lib/src/p%20x.dart`, 호스트가 `part 'src/p%2520x.dart'`), 디렉터리 이름(`lib/src%20dir/`
  파일 넷 → `and 1 more`), `--workspace` 멤버(`pkgs/m/lib/src/x%41y.dart`), 생성 파일(`gen%20x.g.dart`),
  인코딩한 슬래시(`a%2Fb.dart`), `source_packages`(`vendor/vend/lib/v%20x.dart`)는 모두 새 줄에만 든다.
  analysis options가 제외한 `lib/legacy/old%20x.dart`는 `options-excluded-files:`에만 든다. `#`·`?`
  이름과 백슬래시 이름은 새 줄에 들고(그래서 문구에 넣었다) `+`·`[]`·`^`·`|`·`<>`·따옴표·한글 이름은 그래프에
  있어 세지 않는다. 링크 넷
  (루트 안 파일·디렉터리·같은 디렉터리·루트 밖)은 출력이 바이트 단위로 같다. 이름에 `%20`이 든 디렉터리
  안의 프로젝트(이름은 정상)는 줄이 없다(패키지 폴더 아래 상대 경로만 URI가 된다). 모든 경우 finding ID와
  종료 코드가 같다. 캐시 적중·`--incremental` 두 번·파일 변경 뒤 증분·퍼센트 이름↔정상 이름 바꾸기가 전체
  분석과 같다.
- 2(`d839b9e` 이전 판으로 잰 것): 루트도 `pkgs/nest/sub`를 나열(pub은 거부, 손으로 만든 package config) →
  줄 없음. 없는 디렉터리 → 센다. 더 안쪽 `pkgs/nest/sub/inner`만 집계 → `sub`를 센다.
  `source_packages: [pkgs/nest/sub]` → 줄 없음(lib/ 분석). Dart 파일 없는 중첩 멤버 → 센다.
  `deps --workspace`·`query --workspace`도 같은 줄을 싣는다(중첩 멤버 pubspec은 `deps`가 감사하지 않는다).
- 2(최종 바이너리): `**` → 패턴 줄(이전 판은 침묵). 맞는 것 없는 `nothing_*`(pub은 거부) → 패턴 줄.
  `/etc`·`../../../outside`·`ok`(pub 거부) → `pkgs/nest/ok`만(이전 판은 `../outside, /etc`도 반향).
  `loop -> .` 링크 → 줄 하나로 끝남. `group*/x`(중간 글자 마디) → `group1/x, group2/x`(pubspec 없는
  `group3` 제외). 숨김 `.hid`만 맞는 `*` → 패턴 줄. 35단계 사슬 → 32줄과 `were not followed` 한 줄(0.5초).
  `p*`가 2,000개를 고르는 경우 → 줄 하나(앞의 셋과 `and 1997 more`), 전체 3.66초(`origin/main` 3.71초).
  글롭이 고르는 패키지를 더한 뒤 캐시 적중·`--incremental`이 새로 분석한 결과와 같고, pubspec 없는 빈
  디렉터리를 더하면 출력이 그대로다.

### 코퍼스 델타

- 단일 패키지: pub cache의 게시 패키지 75개(이름마다 최신 버전, `analyzer`·`_fe_analyzer_shared` 제외)에
  캐시 패키지 전부를 담은 package config을 손으로 만들어(pub 해석과 같지 않음) `dead`·`dead --closed-app`
  150건을 비교했다. 종료 코드와 stdout이 모두 바이트 단위로 같다(`dead` 종료 0이 41, 1이 34. 이 캐시의
  `lib/`에는 퍼센트 이름이 없다).
- workspace: 같은 캐시의 게시 패키지 30개를 멤버로 둔 workspace(루트 `publish_to: none`, package config
  손으로 만듦)의 `dead --workspace`가 바이트 단위로 같다(405,293바이트, 종료 1). 게시 패키지에는 중첩
  `workspace:`가 없다.

## PR #167 독립 리뷰 반영

리뷰는 `d839b9e`에서 차단 0을 냈다. `unresolved-files:`(빈 파일·주석만·구문 오류·고아 part·테스트·링크·
유니코드 이름은 세지 않음, 제외된 생성 `%20` 파일은 한 번만 셈, 캐시·증분·사용자 캐시 경로 일치, 정렬·
이스케이프)와 impact-precheck 결론은 확인됐다. 중첩 멤버 쪽 지적을 새 커밋으로 반영했다.

- SF1(글롭이 조용히 빠짐): `sub_*`·`*`는 글롭 앞 디렉터리가 멤버 자신이라 멤버 `lib/` 파일 때문에 항상
  빠졌다(`Unused_sub_x` 미분석인데 줄 없음). `packages/*`는 p1이 `source_packages`면 p2까지 숨었다. →
  `*`·`?` 글롭을 패키지 디렉터리로 펼쳐 디렉터리마다 판정하고, 펼치지 못하면 패턴으로 센다(`856fdd7`).
- SF2(안내가 실패하는 명령): "run dartograph --workspace on pkgs/nest"는 그 멤버가 글롭을 쓰면 종료 2였다.
  → 모든 줄이 "run dartograph on each member root"(단일 패키지 분석, 언제나 됨)를 쓴다. `--workspace`의
  루트 글롭 처리는 바꾸지 않았다(Next Steps).
- SF3(더 깊은 중첩): `pkgs/nest/sub/deeper`가 어디에도 없었다. → 선언된 중첩 멤버 pubspec을 방문 집합·
  깊이 상한으로 따라간다(`856fdd7`, 상한 줄은 `b3eab8f`).
- SF4(`source_packages` 문구): "파일이 이미 분석된다"를 "`lib/`가 분석된다(그 밖은 분석하지 않는다)"로
  고쳤다. 그 경우 줄을 내지 않는 것은 그대로다(`test/`에서만 쓰는 호출자는 보이지 않는다, `main`과 같음).
- nit: 백슬래시 이름(`lib/a\b.dart`, `Uri.parse`가 `/`로 읽음)을 문구·문서·fixture에 더하고 "for example"을
  붙였다(`dd27ec7`). impact 점수 요인에 `test-coverage`(25)를 더했다. pub이 거부하는 절대·`..` 항목은
  출력하지 않는다. CHANGELOG 범위를 `runtime`을 뺀 그래프 명령으로 좁혔다.
- 리뷰 뒤 스스로 찾은 것: 글롭 하나가 2,000개를 고르면 줄 하나가 27,074자였다 → 앞의 셋과 수로 묶었다
  (`b3eab8f`). 앞 커밋은 깊이 상한에서 글롭이 아닌 항목도 "펼치지 않는 글롭"으로 적었다 → 상한 줄을
  따로 둔다. 숨김 디렉터리를 고르면 캐시 키와 어긋난다 → 고르지 않는다.

## impact-precheck 실패 조사 (코디네이터 관측, 변경 없음)

- `main` push 6번 중 `28d75c7`·`acda403`·`7da8267`·`4bd0370`이 실패, `88dd0ee`·`a179b19`가 통과했다.
- 실패 단계는 모두 마지막 `Impact gate (fail on high)`(`dart run dartograph impact --since "$IMPACT_BASE"
  --format github-actions --fail-on high`)이고 종료 1이다. 그 직전 줄이 각각 `risk high (81/100)`
  (`28d75c7`, 284개 영향 심볼), `85/100`(`acda403`, 369), `85/100`(`7da8267`, 306), `81/100`(`4bd0370`, 245)다.
  통과한 둘은 `risk medium (66/100)`(`88dd0ee`)과 `risk low (0/100)`(`a179b19`, HANDOFF만 바꾼 커밋)이다.
- 기준은 맞다. `IMPACT_BASE`는 각각 직전 push의 head(`github.event.before`: `acda403`→`28d75c7`,
  `7da8267`→`acda403`, `88dd0ee`→`7da8267`, `25b38ab`→`4bd0370`)이고 checkout은 `fetch-depth: 0`이다.
  로그의 `echo "::error::comparison base $base is not in the checkout"`는 GitHub가 단계 시작에 찍는 스크립트
  본문(색 코드 `[36;1m`)이고 실행된 줄이 아니다. 로그 6개의 `##[error]`는 `Process completed with exit
  code 1.`뿐이다.
- 의도된 동작이다. 워크플로 주석("게이트(`--fail-on high`)는 기본 브랜치 push와 수동 실행에만 건다.
  붉어지면 정책에 맞게 `--fail-on`을 완화하거나 게이트 단계를 조정한다"), README·README.ko("a `--fail-on
  high` gate on default-branch pushes"), USAGE·TROUBLESHOOTING(`--fail-on` 임계 이상이면 종료 1)이 그렇게
  적는다. 점수는 `inbound-references`(최대 30)·`impact-depth`(20)·`impact-breadth`(15)·`public-api-surface`
  (5)·`test-coverage`(관련 테스트가 없으면 25)·`cycle-participation`(15)의 합(상한 100)이라, 테스트가 있는
  핵심 파일을 바꾸는 큰 스쿼시 PR은 81~85로 high가 된다. 고치려면
  예시 워크플로의 정책(임계를 낮추거나 이 저장소에서는 게이트를 정보용으로 두기)을 바꿔야 하므로 사용자
  결정으로 남긴다.

## 이슈 #160 (`Analysis failed: unable to index the package.`)

- 제보 본문은 비어 있다(제목만). 2026-11-04 저장소 계정 댓글에 답이 없다. 새 댓글은 사용자 승인
  뒤에만 단다. 제보자 확인 전에는 이슈를 닫지 않는다(PR은 `Refs #160`). 이번 브랜치는 #160과
  관계없다. 원인별 정리는 HANDOFF-HISTORY의 PR #164 시점 원문 절에 있다.

## 검증

- 도구: 이 컨테이너에 Dart가 없어 이전 세션이 내려받아 둔 SDK(3.13.3·3.11.0)를 썼다. `packet-ask`도
  없어 GLM 리뷰는 받지 못했다(독립 리뷰가 대신했다). 테스트·바이너리 실행은 `HOME`을 스크래치로 두고
  (`PUB_CACHE=/root/.pub-cache`) 돌렸다.
- PR #167 리뷰 반영 뒤(`b3eab8f` 코드, `9502e05`은 테스트만 더함):
  - Dart 3.13.3(analyzer 14.7.0): `dart format --output=none --set-exit-if-changed .` 변경 없음,
    `dart analyze --fatal-infos` 깨끗. 일반 단계(`dart test -j 2 --timeout=4x
    --exclude-tags=global_activation --coverage=…`) 1,252 통과·22 건너뜀·실패 0(22분 34초,
    `self_analysis_test` 포함). 이 단계만의 제품 라인 커버리지 12,837/13,673(93.89%, 기준 90%). 새 코드에서
    실행되지 않은 줄은 깊이 상한·맞는 것 없는 글롭·Windows 대소문자·읽기 실패 분기였고, 앞의 둘은
    `9502e05`의 테스트가 실행한다(그 파일 6개를 3.13.3·3.11.0에서 따로 돌려 통과).
  - CLI 계약(`tool/verify-cli-contract.sh`, 스스로 컴파일) 243 ok·`CLI contract passed`, 오탐 코퍼스 종료 0,
    `tool/check-analyzer-boundary.sh` 통과. `tool/verify-global-activation.sh`는 이번에 다시 돌리지 않았다
    (설치 경로는 그대로, `e36ee10`에서 239 ok·통과).
  - Dart 3.11.0(analyzer 14.5.0), 별도 worktree(`b3eab8f`): 포맷 변경 없음, `dart analyze --fatal-infos`
    깨끗, 관련 테스트 109개(새 두 파일, `pub_workspace`·`options_excluded_files`·`source_packages`·
    `public_libraries`·`incremental_analysis`·`incremental_cache`·`member_file_findings_cli`·`deps_cli`·
    `options_excluded_files_cli`·`reachability_analyzer`, `-j 1 --timeout=4x`) 통과.
  - 코퍼스(`b3eab8f` 바이너리): 단일 패키지 75개 `dead`·`dead --closed-app` 150건과 30개 멤버 workspace
    `dead --workspace`(405,293바이트)가 `origin/main`과 바이트 단위로 같다.
  - 자기 분석(AOT 바이너리, `dg-main`과 바이트 단위로 같다): `dead`는 테스트 fixture 파일 finding 1개
    (`test/index/fixture/lib/platform.dart`, 이전과 같음), `rules --strict --config tool/module_layers.yaml`
    위반 0, `cycles --level file`은 cli 모듈 안(`dartograph_cli` ↔ `mcp_server`) 하나뿐이다.
  - 회귀 테스트: 새 테스트 9개를 `d839b9e` 코드에서 돌리면 6개가 실패하고 대조 3개(퍼센트 파일 없음,
    `--workspace` 없음, `pkgs/nest` 루트)는 통과한다. 변형(재귀 빼기, 와일드카드를 글자 그대로, 분석
    확인 빼기, 펼치지 못한 글롭 버리기, 맞는 것 없는 글롭 버리기, 셋으로 묶기 빼기, 따라가지 않은 패키지
    세지 않기, 옛 안내 문구, 증분 경로에 빈 목록)이 각각 하나 이상을 실패시킨다.
  - `dart pub publish --dry-run`은 이 HANDOFF 커밋 뒤 깨끗한 트리에서 경고 0이다.
- `d839b9e`까지의 검증(이전 기록): 3.13.3 일반 단계 1,252 통과·실패 0(`055cfa3`), CLI 계약 243 ok,
  `verify-global-activation.sh` 239 ok(`e36ee10`), 3.11.0 관련 109개 통과, 같은 코퍼스와 자기 분석이
  `origin/main`과 같았다.

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
  임시 루트마다 항목을 남기기 때문이다(아래 Next Steps). git 커밋은 실제 `HOME`으로 한다(전역 git
  설정).
- 캐시 신원을 올리지 않고 문구만 바꾼 개발 중 바이너리를 같은 `HOME`에서 돌리면 이전 문구의 캐시
  항목이 나온다. 문구를 바꾼 뒤에는 `HOME`을 새로 둔다.

## 리뷰 절차의 대체

AGENTS.md는 PR마다 GLM 리뷰(`packet-ask`)를 요구한다. 이 환경에는 `packet-ask`가 없어 이번 브랜치도
GLM 리뷰를 받지 못했다. PR을 열면 코디네이터가 독립 리뷰를 받거나, GLM을 쓸 수 있는 환경에서
이 delta를 리뷰한다.

## Next Steps

- 푸시는 코디네이터가 한다. 두 SDK CI와 CI에서만 확실히 도는 `global_activation` 태그·커버리지
  90% 게이트 결과를 PR에서 확인한다.
- 다음 릴리스(0.18.0 후보)는 CONTRIBUTING 절차를 따른다. 게시 전에 이슈 #160에 수정 버전을
  안내할지 사용자에게 확인한다.
- 사용자 결정이 필요한 것:
  - impact-precheck 게이트 정책(위 조사). 지금은 큰 PR의 머지 커밋마다 붉어진다.
  - `query` 문서의 limitations를 주제에 맞게 좁히기(5차에서 남긴 결정).
  - 대표 라이브러리가 아닌 export 전용 최상위 라이브러리(예: `collection`의 `lib/algorithms.dart`)는
    게시 패키지에서도 dead 파일로 보고되고 `public-libraries:`에도 세지지 않는다.
- 이번에 보고 남긴 것(재현함, `origin/main`과 같은 동작):
  - `--workspace` 없이 `source_packages: [pkgs/sp]`이고 `pkgs/sp`가 루트 `workspace:` 멤버면
    `workspace-members-not-indexed: pkgs/other, pkgs/sp are separate workspace packages; …`가 나온다.
    실제로는 `pkgs/sp/lib/`가 분석되고(같은 실행의 finding이 `pkgs/sp/lib/sp.dart`에 있다) `test/` 등은
    분석되지 않는다(`pkgs/sp/test`에서만 쓰는 `spOnlyTest`가 미도달로 보고된다). 줄은 반만 참이다. 같은
    모양의 이웃: 루트 `workspace: [example]`이면 `--workspace` 없이도 `example/`가 루트 표준 디렉터리라
    통째로 분석되는데(`package:exm_example/orphan.dart` finding) 같은 줄이 `example`을 "separate … run on
    each member root"로 적는다. 멤버마다 실제 분석 범위(루트 표준 디렉터리 안·`source_packages`의 `lib/`만·
    분석 안 함)를 나눠 적어야 하는데, 문구·키를 새로 정해야 해서 이번 범위에서 뺐다.
  - 루트 pubspec의 글롭 항목(`workspace: [pkgs/*]`, pub은 언어 버전 3.11부터 받아들인다)을
    `--workspace`가 펼치지 않는다. 모든 항목이 글롭이면 `Analysis failed: --workspace resolved no members:
    every declared workspace entry was skipped (pkgs/*)`(종료 2), 일부면 `workspace-members-not-indexed:
    pkgs/* are declared but were not indexed (unreadable member directory or pubspec)`(이유가 틀림)다.
    중첩 멤버 줄의 `*`·`?` 펼치기(위 2절)를 루트 해석에도 쓸 수 있지만 집계 범위가 바뀌는 행동 변경이라
    이 PR에서 하지 않았다. 관측한 pub 의미: `pubspec.yaml`이 있는 디렉터리만, 숨김 포함, `**`는 재귀, 맞는
    것이 없으면 실패. dart-lang/pub 원본은 이 세션에서 읽을 수 없었다.
  - 중첩 멤버 줄의 남은 빈틈: `**`·`[...]`·`{...}`·`\` 글롭은 펼치지 않고 패턴으로만 센다. 숨김 디렉터리는
    고르지 않는다(pub은 고른다). `source_packages`인 중첩 멤버는 `lib/`만 분석되는데 줄이 없다.
  - `runtime`·`routes`·`bridges`·`schema`도 analyzer가 해석하지 않은 유닛을 조용히 건너뛴다
    (`resolveProjectUnitsEach`의 `if (result is ResolvedUnitResult)` 등). 각 명령의 한계 계약에 맞춰
    세는 것은 별도 작업이다.
- 이전부터 남은 것:
  - `source_packages`의 패키지는 대표 라이브러리 보존도 `public-libraries:`도 적용하지 않는다(로컬
    path 의존성을 앱 내부 코드로 본다, 기존 동작). 게시하는 로컬 패키지를 그렇게 다룰지는 별도 판단이다.
  - 일반 테스트 한 번이 실제 사용자 캐시 `~/.cache/dartograph`에 임시 루트마다 새 항목을 남긴다.
    임시 패키지를 분석하는 CLI·`dart run` 테스트 30여 파일이 `userCacheEnvironment`나
    `XDG_CACHE_HOME`을 격리하지 않는다. test/AGENTS.md의 "격리 캐시" 규칙과 맞지 않는 테스트 쪽
    후속이다(이번에 더한 테스트는 격리한다).
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
`28d75c7`까지의 `Unreleased`는 미발행이야. 브랜치 `ccr-37904670-hxdjsx`의 6차 수정
(`unresolved-files:` 한계, `--workspace` 중첩 멤버 한계)이 푸시됐는지와 CI는 GitHub에서 확인해줘.
impact-precheck 게이트 실패는 의도된 `--fail-on high`라서 정책 결정 전에는 바꾸지 마. 릴리스는 지시가
있을 때 CONTRIBUTING 절차를 따라. #160은 Refs로만 연결돼 있으니 제보자 확인 전에는 닫지 말고, 새
댓글은 승인 뒤에만 달아. Next Steps의 제외 항목은 근거 없이 착수하지 마.

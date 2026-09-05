# 설치와 사용

## 설치

dartograph 0.2.0은 Dart SDK 3.11 이상에서 동작하는 순수 Dart 패키지다.

```bash
dart pub global activate dartograph
dartograph --version
```

저장소 소스에서 실행할 때는 `dartograph` 대신 `dart run dartograph`를 쓴다.

## 명령

```text
dartograph graph --format <dot|json|mermaid> <package-root>
dartograph dead --format <text|json|github-actions|sarif> [--baseline <file>] [--since <ref>] <package-root>
dartograph dead --explain <symbol-id> --format json <package-root>
dartograph baseline --write <file> <package-root>
dartograph query <symbol-id-or-name> [--baseline <file>] <package-root>
dartograph query --batch <requests.json> [--baseline <file>] <package-root>
dartograph compare <before-package-root> <after-package-root>
dartograph skill [--install <skills-directory> [--force]]
dartograph bridges --format json <package-root>
dartograph cycles [--strict] <package-root>
dartograph rules --config <yaml-file> [--strict] <package-root>
dartograph metrics [--strict] <package-root>
```

`dead`는 보존 루트에서 도달할 수 없는 선언과 파일을 보고하지만 삭제 판정을 하지 않는다.
`--explain`은 도달 경로나 미도달 근거를 JSON으로 낸다. `baseline`은 현재 finding을 기록하고,
`--since`는 전체 그래프를 만든 뒤 Git 기준 ref 이후 바뀐 파일로 보고 범위를 좁힌다.
`--explain`은 단일 대상의 전체 근거를 묻는 명령이라 `--baseline`·`--since`와 함께 쓰지 않는다.
그래프에 없는 ID는 `known: false`와 종료 코드 64로 구분한다.

`query`는 일치한 심볼의 양방향 관계, 멤버, 보존 경로, baseline 상태를 답한다. 찾지 못한
경우에도 `notFound`와 `limitations`를 함께 낸다. `bridges`는 Flutter 채널 사실을
GRAPH-EXCHANGE v1 JSON으로 낸다. `rules`의 YAML은 `allow` 또는 `deny` 규칙을 사용한다.
패키지의 `lib/<package-name>.dart`가 export한 공개 선언과 공개 멤버는 외부 소비자 API로
보존하고 `query`에서 `reason: publicApi`로 설명한다.

모든 JSON 목록과 키는 결정적 순서로 출력된다. 같은 입력은 byte-for-byte 같은 결과를
내야 한다. 단, `bridges`의 `generatedAt`은 실행 시각이다.

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

| 코드 | 뜻 |
|---:|---|
| 0 | 명령 성공. 일반 보고 모드는 finding이 있어도 성공할 수 있음 |
| 1 | `dead` finding, 또는 `--strict` 분석 명령의 finding |
| 2 | 패키지를 신뢰할 수 있게 분석하지 못함 |
| 64 | 잘못된 명령·인자, 또는 `query`/`dead --explain` 대상이 그래프에 없음 |

## CI 예제

전체 Git 이력이 있어야 `--since`의 merge-base를 계산할 수 있다.

```yaml
- uses: dart-lang/setup-dart@v1
- run: dart pub global activate dartograph 0.2.0
- run: dartograph dead --format github-actions --since origin/main .
```

`dead`는 finding 자체가 코드 1을 반환하므로 `--strict` 인자가 필요하지 않다.
`cycles`, `rules`, `metrics`는 `--strict`를 붙였을 때만 finding을 코드 1로 바꾼다.

## 분석 한계

- 조건부 import/export는 공개 analyzer가 고른 단일 구성만 분석한다.
- 동적 디스패치, 문자열 route, 네이티브 진입점은 정적 그래프가 완전히 증명하지 못한다.
- 생성 파일은 보수적으로 보존하며 오래된 산출물을 한계로 보고한다.
- `main` 진입점은 여러 개일 수 있다. v0.1은 `lib/`, `bin/`, `example/`의 모든 `main`을 보수적으로 보존하므로 분석 전에 실제 build target을 확인한다.
- finding은 검토할 후보와 근거이며 삭제 지시가 아니다.
- `source-analysis-errors`, `source-unresolved-invocations`, `source-conditional-configuration`은
  관측된 **파일**의 finding에 붙는다. 특정 선언이 원인이라고 단정하지 않는다.
  다른 파일에 관측된 동적 호출도 해당 선언을 사용할 수 있으므로 전역 경고도 유지한다.
  한계 목록이 비어 있어도 분석의 완전성이나 안전한 삭제를 보증하지 않는다.
- `bridges`는 Flutter services의 직접 import만 채널 provenance로 사용한다. re-export
  barrel을 거친 사용은 추측해 연결하지 않고 `flutter-services-reexports` limitation으로
  보고한다.

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

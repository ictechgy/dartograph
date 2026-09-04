# 설치와 사용

## 설치

dartograph 0.1.1은 Dart SDK 3.11 이상에서 동작하는 순수 Dart 패키지다.

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
- run: dart pub global activate dartograph 0.1.1
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

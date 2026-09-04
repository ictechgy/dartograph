# 결정: `package:analyzer` 14.3.0을 원천으로 고정한다

- 상태: 채택
- 날짜: 2026-09-04
- 범위: Phase 0 원천 검증

## 결정

1. v0.1은 `package:analyzer` **14.3.0**을 정확히 고정한다.
2. analyzer를 import하는 제품 코드는 `lib/src/index/`에만 둔다.
3. 이름 있는 정점 ID는 `library URI + enclosing lookup-name path`로 만든다.
4. `package:` URI가 없는 프로젝트 파일은 절대 `file:` URI 대신
   `project:<root-relative-path>`를 쓴다.
5. 이름 없는 extension은 이름 경로만으로 구분할 수 없으므로
   `선언 source URI + canonical fragment offset`을 보조키로 쓴다.
6. 생성 파일은 `.g.dart`, `.freezed.dart`, `.pb.dart` suffix로
   `synthesized` 표시하되 선언과 참조는 버리지 않는다.
7. 정상 analyzer 범위에 제외된 생성 파일만 다시 더한다. 프로젝트가 명시적으로
   제외한 다른 파일은 되살리지 않는다.
8. 내용 해시와 분석기 신원을 키로 쓰는 영속 사실 캐시를 v0.1에 넣는다.
   Phase 1에서는 캐시 경계를 먼저 두고, 구현은 첫 대형 그래프가 나온 뒤 붙인다.

## 실험 환경

| 항목 | 값 |
|---|---|
| 하드웨어 | Apple M4 Pro, 24 GiB, arm64 |
| OS | macOS 26.6.2 (25G83) |
| 프로브 | `experiments/phase-0/analyzer_probe` |
| analyzer | 14.3.0 |
| 기본 Dart | 3.13.3 |
| Flutter 샘플·플러그인 | Flutter 3.47.2 / Dart 3.13.2 |
| Invoice Ninja | Flutter 3.44.1 / Dart 3.12.1 |

프로브의 `elapsedMs`는 `AnalysisContextCollection` 생성, 대상 파일 열거,
resolved unit 요청, AST 순회, collection dispose를 포함하고 JSON 인코딩은 포함하지 않는다.
`references`는 그래프 대상 element로 해석된 `SimpleIdentifier` 수다. 타입 리터럴 등
최종 간선 전체를 세는 수치가 아니므로 성능 비교에만 쓴다.

## 도그푸딩 대상

| 대상 | 리비전 | 선택 이유 |
|---|---|---|
| `flutter/samples` `navigation_and_routing` | `463e365e` | `go_router`를 쓰는 작은 Flutter 앱 |
| `flutter/packages` `path_provider_platform_interface` | `9af9c607` | 실제 `MethodChannel`과 `invokeMethod` 호출 |
| `flutter/packages` `path_provider_foundation` | `9af9c607` | 조건부 export와 FFI `.g.dart` |
| `invoiceninja/flutter` | `59fa2c8f` | 생성 코드 제외 `lib/` 311,211줄, 세 코드 생성·라우팅 스택 사용 |

Invoice Ninja를 고르기 전에 다음 후보를 실제로 확인하고 제외했다.

| 후보 | 제외 이유 |
|---|---|
| `localsend/localsend` | 생성 코드 제외 `app/lib` 25,387줄, 지정 스택과 다름 |
| `AppFlowy-IO/AppFlowy` | 규모·스택은 충족하지만 Rust protobuf·아이콘·번역 생성물이 없어 재현 가능한 분석 상태가 아님 |
| `hiddify/hiddify-app` | 생성 코드 제외 `lib/` 34,444줄 |
| `ente-io/ente` | `go_router`를 사용하지 않음 |
| `chen08209/FlClash` | 56,250줄이지만 `go_router`를 사용하지 않음 |

## 측정 결과

최종 프로브 결과다. 각 대상은 먼저 그 저장소가 요구하는 Flutter로 `pub get`과
`flutter analyze --no-pub`을 수행했다.

| 대상 | 파일 | 생성 파일 | 선언 | 참조 | 프로브 진단 | 시간 |
|---|---:|---:|---:|---:|---:|---:|
| `navigation_and_routing` | 19 | 0 | 102 | 329 | 0 | 7.123초 |
| `path_provider_platform_interface` | 5 | 0 | 41 | 163 | 0 | 6.495초 |
| `path_provider_foundation` | 9 | 1 | 136 | 580 | 0 | 7.687초 |
| Invoice Ninja | 2,310 | 181 | 48,760 | 370,450 | 20 | 35.968초 |

모든 대상에서 정점 ID 충돌은 0개였고 프로젝트 내부 절대 `file:` ID도 0개였다.
Invoice Ninja의 고정 Flutter 분석은 26.9초, 0 issues였다. analyzer 14.3.0 프로브는
프로젝트 기준 analyzer보다 새 버전이라 16개 파일에서 오류 1, 경고 18, TODO 1을 냈다.
따라서 이 대상의 참조 수는 정확성 기준값으로 쓰지 않지만, 전체 resolved-unit 순회 시간과
API 호환성 측정에는 사용한다.

`path_provider_foundation`은 제외된 FFI 생성 파일을 처음 직접 해석했을 때 32.296초,
후속 실행에서 8.163초가 걸렸다. OS 파일 캐시 영향이 크므로 단일 warm 수치만으로
영속 캐시가 불필요하다고 판단할 수 없다.

## 확인한 동작

### 정점 ID

- 이름 있는 선언은 같은 소스의 별도 프로세스 실행에서 같은 URI와 이름 경로를 냈다.
- `lib/` 선언은 `package:` URI를 얻지만 `test/` 선언은 절대 `file:` URI를 얻는다.
  후자는 프로젝트 상대 `project:` URI로 정규화해야 클론 위치에 독립적이다.
- 이름 없는 extension은 이름 경로가 비어 충돌한다. 서로 다른 `part` 파일의 같은 offset도
  충돌하므로 호스트 library URI만이 아니라 선언 source URI가 필요하다.
- canonical offset은 앞쪽 소스 편집에 따라 바뀐다. 이름 없는 extension ID는 이름 있는
  선언보다 약한 안정성을 가진다는 제한을 출력 스키마에 남긴다.

### `part`와 생성 코드

- `part_host.g.dart`의 `ResolvedUnitResult.libraryElement.uri`는 part 자체가 아니라
  호스트인 `package:.../part_host.dart`였다.
- 위치와 정체성은 분리한다. 정점 ID에는 호스트 library URI를 쓰고 진단 위치에는 실제
  part source 경로를 쓴다.
- `analysis_options.yaml`이 `.g.dart`를 제외하면 `contextRoot.analyzedFiles()`에 나타나지 않는다.
  그래도 같은 상위 context의 session에 `getResolvedUnit`을 직접 요청하면 해석할 수 있다.
- 직접 import되는 `ffi_bindings.g.dart`는 독립 library URI를 가진다. suffix 판별은
  part 여부와 독립적으로 적용해야 한다.

### 조건부 import/export

합성 fixture의 `if (dart.library.io)` export는 기본 공개
`AnalysisContextCollection`에서 stub 분기를 선택했다. 14.3.0의 공개 생성자는
declared variables를 받지 않으므로 한 실행에서 한 구성만 볼 수 있다. v0.1은 선택된
구성만 그래프에 넣고 이 사실을 `limitations`에 싣는다. 내부 analyzer API로 여러 구성을
강제로 만들지 않는다.

### API 변화

`AnalysisContextCollection`과 resolved-unit 흐름 자체는 14.3.0 공개 예제와 맞았다.
그러나 analyzer 8~14의 변경 기록에는 매 major마다 element/AST 제거 또는 breaking change가
있다. 실험에서 사용한 현재 표면은 `declaredFragment.element`, `Identifier.element`,
`Element.library`, `Element.enclosingElement`, `Element.firstFragment`다.

특히 예전 코드가 흔히 쓰던 element model V1, `ElementLocation`, `Element.isSynthetic`,
여러 AST member getter가 8~13 사이 제거됐다. API 변화 주장은 확인됐으며 어댑터 격리와
정확한 버전 고정이 필요하다.

## 캐시 결정

캐시는 **필요하다**.

- 311k 사용자 LoC 대상의 전체 순회가 35.968초로 v0.1의 30초 목표를 넘었다.
- 생성 파일 하나의 cold 해석만으로 작은 플러그인이 32초까지 늘었다.
- analyzer는 dartograph가 다음 프로세스에서 재사용할 프로젝트 사실 파일을 남기지 않는다.

캐시 키에는 파일 내용 해시, analyzer 버전, Dart SDK 신원, 조건부 구성,
dartograph 분석 revision을 포함한다. 캐시는 정확성을 바꾸는 원천이 아니라 resolved fact의
재사용 계층이다. 첫 실행 30초 목표는 캐시와 별개로 병렬화·파일 가지치기를 다시 측정한다.

## Phase 1에 넘기는 제약

- analyzer 타입은 `lib/src/index/` 밖으로 노출하지 않는다.
- core의 ID 타입은 `package:`와 `project:` library ID를 모두 표현한다.
- part source 위치와 library 정체성을 별도 필드로 보존한다.
- 프로젝트 제외 목록과 생성 파일 재포함 목록은 한 곳에서 계산한다.
- analyzer 진단 수와 조건부 구성은 분석 결과의 limitation으로 전달한다.
- 캐시가 없어도 맞고, 캐시를 켜도 같은 그래프가 나오는 계약 테스트를 둔다.

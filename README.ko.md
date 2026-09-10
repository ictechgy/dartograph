# dartograph

Dart/Flutter 코드베이스를 위한 질의 가능한 의존성 그래프. [cartograph](https://github.com/ictechgy/cartograph)(Swift)의 자매 프로젝트다.

[English README](README.md)

**MIT 라이선스이며 상업적 사용을 포함해 영구 무료다.** 유료 티어, 라이선스 키, 좌석 수·LoC 제한, 텔레메트리, 계정 로그인은 영원히 없다.

이름은 **Dart**와 cartograph를 섞었다.

## 무엇을 하려는가

DCM(구 dart_code_metrics)은 Flutter 프로젝트의 미사용 코드·파일을 검사한다 — 그리고 2023년에 유료로 전환했다. 무료 티어는 **1인·50k LoC 이하**라, 팀이거나 더 큰 프로젝트면 돈을 내야 한다.

dartograph는 그 자리를 채운다: **상업적 사용을 포함해 영구 무료(MIT)** — Periphery가 상업화된 뒤 cartograph가 Swift에서 그랬던 것과 같다.

- 진실의 원천은 텍스트 검색이 아니라 `package:analyzer`, 즉 Dart 팀의 공식 분석기 패키지다.
- 미사용 코드·미사용 파일·순환 의존·레이어 규칙·아키텍처 지표를 한 그래프에서 낸다.
- 모든 답은 근거를 함께 싣는다. dartograph는 삭제 판정을 내리지 않는다.
- `query`와 `skill`은 처음부터 내장돼 코딩 에이전트가 소비하도록 설계됐다.

**릴리스는 [pub.dev](https://pub.dev/packages/dartograph)와 [GitHub Releases](https://github.com/ictechgy/dartograph/releases)에 공개한다.** 모든 릴리스는 전체 테스트 스위트·라인 커버리지 게이트·패키지 dry-run을 통과하고 실제 공개 Flutter 플러그인 dogfooding을 거친다.

## 설치

dartograph는 순수 Dart CLI라 Flutter SDK를 필요로 하지 않는다. Dart SDK 3.11 이상에서 동작한다.

```bash
dart pub global activate dartograph
dartograph --version
```

## 사용

대부분의 명령은 분석할 Dart 패키지의 루트를 마지막 인자로 받는다. 아래 예시는 전역 설치를 가정한다; 소스 체크아웃에서는 각 명령 앞에 `dart run`을 붙인다(예: `dart run dartograph graph --format dot .`).

```bash
# 설정 템플릿 초기화
dartograph init .

# 그래프 & 죽은 코드
dartograph graph --format dot .
dartograph graph --format html .
dartograph dead --format text .

# baseline & 좁혀진 CI 보고
dartograph baseline --write .dartograph-baseline.json .
dartograph dead --format github-actions \
  --baseline .dartograph-baseline.json --since origin/main .

# 심볼 질의
dartograph query ApiClient --baseline .dartograph-baseline.json .
dartograph query --batch requests.json .

# 변경 영향
dartograph compare ../before-checkout ../after-checkout
dartograph affected origin/main .

# Flutter 브리지 사실, 순환, 레이어 규칙, 지표, 에이전트 스킬
dartograph bridges --format json .
dartograph cycles --strict .
dartograph rules --config layers.yaml --strict .
dartograph metrics .
dartograph skill
```

전체 인자·출력 형식·종료 코드·CI 예시는 [`doc/USAGE.md`](doc/USAGE.md)에 있다.

- `--since`는 전체 프로젝트 그래프를 먼저 만든 뒤 보고 위치를 변경 지점으로 좁힌다. 기준 ref 이후 커밋, staged·unstaged 변경, untracked 파일을 모두 다루므로 CI에서는 전체 Git 이력이 필요하다. 출력 형식은 `text`, `json`, `github-actions`, `sarif`다.
- `--baseline <file>`은 `baseline --write`로 기록한 finding을 정확히 억제해, 알려진 죽은 코드가 CI를 실패시키지 않고 새 finding만 드러나게 한다.
- `query`는 한 심볼에 관한 질문에 답한다 — 양방향 이웃, 멤버, 보존 경로, baseline 상태, 한계 — 전체 그래프를 덤프하는 대신 cartograph와 같은 필드 이름을 쓴다.
- `affected <git-ref>`는 어떤 라이브러리가 Git 리비전 이후 변경됐는지, 어떤 라이브러리가 그것들에 전이적으로 의존하는지를 보고하며, 각 의존자는 변경 라이브러리까지의 최단 의존 경로를 근거로 싣는다.
- `compare <before> <after>`는 같은 패키지의 두 체크아웃을 비교해 추가·제거된 정점·간선·보존 루트와 새로 미도달·도달이 된 것을 낸다(새로 미도달이 된 선언은 before-path·제거된 간선·제거된 루트를 근거로 싣는다). `--since`와 달리 보고 위치를 필터링하는 게 아니라 두 그래프 전체를 비교한다.
- `bridges`는 Flutter `MethodChannel` 생성과 `invokeMethod`·`invokeListMethod`·`invokeMapMethod` 사실을 [`GRAPH-EXCHANGE`](https://github.com/ictechgy/isthmus/blob/main/docs/GRAPH-EXCHANGE.md) v1로 낸다 — [isthmus](https://github.com/ictechgy/isthmus)가 플랫폼 경계에 걸쳐 조인하는 브리지 사실 형식이다(cartograph도 생산한다). 각 사실은 MethodChannel provenance, 어휘 범위, UTF-8 위치, UTC 밀리초 시각을 싣는다. 동적 채널 이름은 사실로 남고, 미귀속 호출·잘못된 형태의 호출·부분 파싱·EventChannel·BasicMessageChannel(현재 분석 범위 밖)은 사실로 읽히지 않고 한계로 집계된다.
- `skill`은 바로 붙여넣을 수 있는 스킬을 출력하거나 `--install <dir>`로 디렉터리에 설치한다 — 코딩 에이전트가 근거 기반 답을 위해 dartograph를 어떻게 다루는지 가르치는 스킬이다.
- `cycles`, `rules`, `metrics`는 기본적으로 보고만 하고, `--strict`일 때 finding이 종료 코드 1이 된다. 지표는 라이브러리별 Ca, Ce, 불안정도, 추상도, 주계열(main sequence) 거리다 — 각 항목은 보고된 허용 오차 기준 영역(`main-sequence`·`zone-of-pain`·`zone-of-uselessness`, 결합이 전혀 없으면 `isolated`)도 함께 실는다.
- `init`은 프로젝트 루트에 주석 달린 `dartograph.yaml` 설정 파일 템플릿을 생성한다(기존 설정이 있으면 `--force`로 덮어쓴다).

`// dartograph:ignore` 줄 주석은 그 주석이 위에 오는 선언의 dead 보고를 억제한다(`retentionReason: inlineIgnore`로 보존) — 저장소 작성자의 결정이며 그래프 자체에 기록된다.

dartograph는 무엇을 삭제해도 안전한지 판정하지 않고 코드를 삭제하지도 않는다. 모든 finding에 붙은 근거와 한계는 사람의 검토가 필요하다. 프로젝트 전역 도달성 도구이며 `dart analyze`의 라이브러리 내부 `unused_element`를 재구현한 것이 아니다.

## 분석 한계와 보장

한계:

- 조건부 import/export: analyzer가 고른 단일 구성만 관측된다.
- route table과 연결되지 않은 문자열 route는 한계로 보고되며 삭제 근거로 쓰이지 않는다.
- 소스보다 오래된 생성 코드는 한계로 보고된다; 생성 선언 자체는 보수적으로 보존된다.
- 한 패키지에는 `main` 함수가 여러 개일 수 있다. 기본적으로 `lib/`, `bin/`, `example/` 아래의 모든 `main`이 보존된다. 실제 빌드 대상을 `dartograph.yaml`의 `entry_points`로 선언하면 그 파일들의 `main` 함수로 보존을 좁힌다(템플릿은 `dartograph init`으로 생성할 수 있다).
- `lib/<package-name>.dart`가 export하는 공개 선언·공개 멤버는 외부 소비자 API로 보존된다.
- 동적 호출과 네이티브 동작은 정적 그래프로 완전히 증명할 수 없다.
- `bridges`는 `package:flutter/services.dart`의 직접 import만 provenance로 인정한다. Flutter services를 다시 export하는 배럴 경유 사용은 사실에서 제외되고 `flutter-services-reexports` 한계로 보고된다.

보장:

- 분석 캐시는 분석 대상 밖의 OS 사용자 캐시(`~/Library/Caches`, `$XDG_CACHE_HOME`/`~/.cache`, `%LOCALAPPDATA%`) 아래 `dartograph/<project-root-hash>`에 둔다. 프로젝트·의존 내용, mtime, 패키지 해석, Dart SDK, 분석 revision이 바뀌면 자동으로 무효화된다. 캐시가 없거나 손상돼도 결과는 절대 바뀌지 않고 분석 시간만 더 든다.
- 보존 루트가 20개를 넘는 finding은 전체 개수, 앞 20개 샘플, `retentionRootsTruncated: true`를 기록해 출력을 제한한다. 근거가 잘렸다는 사실은 절대 숨기지 않는다.

## 문서

저장소 설계 문서는 한국어로 쓴다.

| 문서 | 내용 |
|---|---|
| [`doc/PRD.md`](doc/PRD.md) | 무엇을·누구를 위해·어디까지·무엇을 하지 않을지 |
| [`doc/PLAN.md`](doc/PLAN.md) | 단계별 계획 |
| [`doc/RESEARCH.md`](doc/RESEARCH.md) | 확인된 사실·확인되지 않은 주장·출처 |
| [`doc/DECISION-analyzer.md`](doc/DECISION-analyzer.md) | analyzer 버전·정점 ID·생성 코드·캐시 결정 |
| [`doc/USAGE.md`](doc/USAGE.md) | 설치·명령·종료 코드·CI 사용법 |

## 기여와 보안

기여 절차: [`CONTRIBUTING.md`](CONTRIBUTING.md). 취약점 제보: [`SECURITY.md`](SECURITY.md). 릴리스 변경점: [`CHANGELOG.md`](CHANGELOG.md), 한국어본은 [`CHANGELOG.ko.md`](CHANGELOG.ko.md).

## 라이선스

MIT. **상업적 사용을 포함해 영구 무료다.** 이것은 이 프로젝트의 기능이지 각주가 아니다 — 약속은 이 README의 첫 화면에 있고, 라이선스를 바꾸지 않겠다는 서약은 `doc/PRD.md`에 기록돼 있다.

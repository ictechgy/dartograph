# dartograph

Dart/Flutter 코드베이스를 위한 질의 가능한 의존성 그래프. [cartograph](../cartograph)(Swift)의 자매 프로젝트다.

**MIT 라이선스이며 상업적 사용을 포함해 영구 무료다.** 유료 티어 · 라이선스 키 ·
좌석 수 · LoC 제한 · 텔레메트리 · 계정 로그인은 영원히 없다.

이름은 **Dart** + cartograph.

## 무엇을 하려는가

Flutter 의 미사용 코드 · 파일 검사는 DCM(구 dart_code_metrics)이 가지고 있고, DCM 은 2023 년에 유료로 전환했다. 무료 티어가 있지만 **1인 · 50k LoC 이하** 다. 팀이거나 그보다 큰 프로젝트면 돈을 내야 한다.

dartograph 는 그 자리를 **상업적 사용을 포함해 영구 무료(MIT)** 로 채운다. Periphery 가 상업화되며 남긴 자리를 cartograph 가 채운 것과 같은 이유다.

- `package:analyzer` — Dart 팀이 배포하는 공식 분석기 — 를 원천으로 쓴다. 텍스트 검색이 아니다
- 미사용 코드 · 파일 · 순환 의존 · 레이어 규칙 · 지표를 한 그래프 위에서 낸다
- 모든 판정에 근거를 붙인다. 삭제 판정은 내지 않는다
- 에이전트가 소비할 것을 전제로 `query` 와 `skill` 을 처음부터 갖춘다

세 자매 프로젝트 중 **가장 싸게 만들 수 있다.** 원천이 공식이고 안정적이며 활발하다(2026-09 기준 `analyzer` 14.3.0).

**v0.1.0 릴리스 후보:** 전체 테스트·커버리지·패키지 dry-run과 실제 Flutter 패키지
도그푸딩을 통과했다. 태그와 pub.dev 발행은 아직 수행하지 않았다.

## 설치

순수 Dart CLI이며 Flutter SDK에 의존하지 않는다. Dart 3.11 이상에서 설치한다.

```bash
dart pub global activate dartograph
dartograph --version
```

소스 체크아웃에서는 `dart run dartograph`로 같은 명령을 실행할 수 있다.

## 사용

분석할 Dart 패키지의 루트를 마지막 인자로 넘긴다.

```bash
dart run dartograph graph --format dot .
dart run dartograph dead --format text .
dart run dartograph baseline --write .dartograph-baseline.json .
dart run dartograph dead --format github-actions \
  --baseline .dartograph-baseline.json --since origin/main .
dart run dartograph query ApiClient --baseline .dartograph-baseline.json .
dart run dartograph skill
dart run dartograph bridges --format json .
dart run dartograph cycles --strict .
dart run dartograph rules --config layers.yaml --strict .
dart run dartograph metrics .
```

전역 설치했다면 각 줄의 `dart run dartograph`를 `dartograph`로 바꾼다. 전체 인자,
출력 형식, 종료 코드, CI 예제는 [`doc/USAGE.md`](doc/USAGE.md)에 있다.

`--since`는 전체 프로젝트 그래프를 만든 뒤 보고 위치만 좁힌다. 기준 ref 이후 커밋,
staged·unstaged 변경, untracked 파일을 모두 포함하며 CI에서는 전체 Git 이력을 받아야
한다. 리포트 형식은 `text`, `json`, `github-actions`, `sarif`를 지원한다.

`query`는 전체 그래프 대신 한 심볼의 양방향 이웃·멤버·보존 경로·한계를 cartograph와
같은 필드 이름으로 답한다. `bridges`는 Flutter 채널 생성과 `invokeMethod` 사실을
isthmus `GRAPH-EXCHANGE` 버전 1로 내며, 동적·미귀속·부분 파싱 사실을 숨기지 않는다.
`cycles`·`rules`·`metrics`는 기본적으로 보고만 하고, `--strict`일 때만 발견을 종료
코드 1로 바꾼다. 지표는 라이브러리별 Ca·Ce·불안정도·추상도·주계열 거리를 계산한다.

dartograph는 삭제 가능 여부를 판정하거나 코드를 자동 삭제하지 않는다. 각 finding의
근거와 `limitations`를 사람이 함께 검토해야 한다. `dart analyze`의 라이브러리 내부
`unused_element`를 재구현하는 도구가 아니라 프로젝트 전역 도달성을 묻는 도구다.

## 분석 한계

- 조건부 import/export는 analyzer가 고른 한 구성만 본다.
- 문자열 route가 route table과 연결되지 않으면 한계로 보고하며 삭제 근거로 쓰지 않는다.
- 생성 코드가 소스보다 오래됐으면 한계로 보고한다. 생성 선언 자체는 보수적으로 보존한다.
- `main`은 여러 개일 수 있으며 `lib/`, `bin/`, `example/`의 진입점을 보존한다.
- `lib/<package-name>.dart`가 export한 공개 선언과 공개 멤버는 외부 소비자 API로 보존한다.
- 동적 호출과 네이티브 동작은 정적 그래프가 완전히 증명할 수 없다.

해석 결과 캐시는 분석 대상 밖의 OS 사용자 캐시(`~/Library/Caches`,
`$XDG_CACHE_HOME`/`~/.cache`, `%LOCALAPPDATA%`) 아래 `dartograph/<project-root-hash>`로
분리한다. 프로젝트와 의존 패키지의 내용·mtime, 패키지 해석, Dart SDK 또는 분석 revision이
바뀌면 자동으로 무효화하며, 캐시가 없거나 손상돼도 결과는 같고 분석 시간만 늘어난다.

보존 루트가 20개를 넘는 finding은 출력 폭증을 막기 위해 전체 개수와 앞 20개 sample,
`retentionRootsTruncated: true`를 기록한다. 근거가 잘렸다는 사실은 숨기지 않는다.

| 문서 | 내용 |
|---|---|
| [`doc/PRD.md`](doc/PRD.md) | 무엇을 · 누구를 위해 · 어디까지 · 무엇을 하지 않을지 |
| [`doc/PLAN.md`](doc/PLAN.md) | 단계별 계획 |
| [`doc/RESEARCH.md`](doc/RESEARCH.md) | 확인된 사실 · 확인되지 않은 주장 · 출처 |
| [`doc/DECISION-analyzer.md`](doc/DECISION-analyzer.md) | analyzer 버전 · 정점 ID · 생성 코드 · 캐시 결정 |
| [`doc/USAGE.md`](doc/USAGE.md) | 설치 · 명령 · 종료 코드 · CI 사용법 |

## 기여와 보안

기여 절차는 [`CONTRIBUTING.md`](CONTRIBUTING.md), 취약점 제보 방법은
[`SECURITY.md`](SECURITY.md), 릴리스 변경점은 [`CHANGELOG.md`](CHANGELOG.md)를 따른다.

## 라이선스

MIT. **상업적 사용을 포함해 영구 무료다.** 이것은 이 프로젝트의 기능이지 각주가 아니다 — README 첫 화면에 적고, 라이선스를 바꾸지 않겠다는 약속을 `doc/PRD.md` 에 남긴다.

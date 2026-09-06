# Changelog

## Unreleased

- 심볼릭 링크로 연결된 Dart 소스를 분석 캐시 입력과 bridge 스캔에 포함
  - analyzer는 파일·디렉터리 링크를 모두 따라가 분석하는데 입력 목록에서는 빠져 있어,
    링크 대상을 수정해도 캐시 키가 그대로여서 낡은 그래프를 돌려주던 문제를 수정한다
  - 같은 이유로 누락되던 링크된 소스의 플랫폼 채널 사실도 추출한다
  - 디렉터리 링크는 이미 따라간 실제 경로를 기록해 순환에서 무한 순회하지 않는다
  - 끊어진 링크는 대상이 없으므로 계속 제외한다

- `dartograph.yaml`의 `entry_points`로 실제 build target을 선언해 `main` 보존 루트를 좁히는 옵션 추가
  - 설정하지 않으면 기존 보수 정책(`lib/`·`bin/`·`example/`의 모든 `main`)을 유지한다
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

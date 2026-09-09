# Contributing

제품 범위는 [PRD](doc/PRD.md), 공통 작업 원칙은 [AGENTS.md](AGENTS.md)가 정본입니다.
Dart 최소 버전은 pubspec.yaml, 검증 SDK는 .github/workflows/ci.yml을 확인합니다.

pub.dev 노출 문서는 영어가 정본입니다: README.md(영어)·README.ko.md(한국어),
CHANGELOG.md(영어)·CHANGELOG.ko.md(한국어) 쌍은 내용을 같은 사실로 유지하고 한쪽만
갱신하지 않습니다. 저장소 내부 문서(doc/, AGENTS.md, CONTRIBUTING.md, SECURITY.md)는 한국어를 유지합니다.
영어 README에서 한국어 문서로 링크할 때는 `(Korean)`을 표기합니다.

## 개발

의존성이 준비되지 않았으면 `dart pub get`을 실행합니다. 로컬 mise 환경에서는
`mise exec dart@3.13.3 -- <command>`를 사용할 수 있습니다.
격리 설치한 pub wrapper도 dart를 실행하므로 SDK가 PATH에 있어야 합니다.

## 검증 선택

| 변경 | 작업 중 필요한 근거 |
|---|---|
| Markdown 지침·사람용 문서 | diff, 링크, 적용 범위와 사실 정합성 |
| 생성되는 skill 안내 | 설치/덮어쓰기 기존 테스트, YAML metadata, 요청별 사용 시나리오 검토 |
| 분석·CLI 행동 | 관련 회귀 테스트와 dart analyze; 오탐은 보존/보고 양방향 사례 |
| 캐시·교환·출력·배포 경계 | 관련 무효화·결정성·호환성·격리 설치 검증 |
| 검증 도구·CI | 변경한 실행 경로와 실패 전파를 확인하고 두 SDK CI 결과 확인 |

버그 수정은 재현 실패부터 확인하고 테스트의 기대값은 제품 구현과 독립적으로 작성합니다.
문구·가역적인 저위험 변경은 소스를 복제하는 assertion을 추가하지 않습니다.
테스트 선택과 확인된 한계를 보고하고, 같은 변경에 성공한 게이트를 관성적으로 반복하지 않습니다.

## CI 게이트

CI는 두 SDK에서 아래 게이트를 유지합니다. Markdown-only PR에도 동일한 required-check 이름을
보존하며, 경로 필터로 검증을 누락하지 않습니다. 로컬 문서 작업에 이 전체 실행을 요구하지는 않습니다.

```bash
dart format --output=none --set-exit-if-changed .
dart analyze
tool/check-coverage.sh
tool/verify-false-positive-corpus.sh
tool/check-analyzer-boundary.sh
tool/verify-cli-contract.sh
dart pub publish --dry-run
```

`check-coverage.sh`는 전체 `dart test`와 제품 라인 커버리지 90% 게이트를 실행합니다.
그 테스트 안의 `test/tool/verify_global_activation_test.dart`가 격리 설치·설치본 CLI 계약을 확인합니다.
따라서 CI에 별도 `dart test`와 `verify-global-activation.sh` 실행을 중복 추가하지 않습니다.
컴파일된 native executable 검증은 `verify-cli-contract.sh`로 별도 유지합니다.
자기 분석 findings 0도 전체 테스트에 포함됩니다. 실패한 검사를 생략하거나 임계값을 낮추지 않습니다.

## 선택 검증과 릴리스

- 반복 질의 성능: `dart run tool/benchmark_query.dart` — 합성 입력 결과 동등성과 시간; 실제 성능 보장은 아닙니다.
- bridge 계약: `dart run tool/verify_bridge_query.dart <isthmus-main.js>` — 합성 Swift fact 왕복; 실제 compiler 검증을 대체하지 않습니다.
- 설치 경계만 재확인할 때: `tool/verify-global-activation.sh`.
- 공개 프로젝트 도그푸딩 대상은 [PLAN](doc/PLAN.md)을 참고하되 현재 환경과 준비 상태를 확인합니다.

승인된 릴리스에서는 pubspec.yaml·toolVersion·CHANGELOG.md(영어)와 CHANGELOG.ko.md(한국어)·설치 예제(README·README.ko·USAGE)·SECURITY.md의 버전을 맞추고,
검증한 commit의 dry-run을 확인한 뒤 게시합니다. pub.dev 성공 후 같은 commit에 태그와 GitHub Release를 연결하고
공개 패키지를 새 캐시에 설치해 확인합니다. 전파 지연 때 동일 버전을 다시 게시하지 않습니다.

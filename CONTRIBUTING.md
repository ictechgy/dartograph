# Contributing

dartograph에 기여해 주셔서 감사합니다. 이 프로젝트의 정본 규칙은
[`AGENTS.md`](AGENTS.md), 제품 계약은 [`doc/PRD.md`](doc/PRD.md)에 있습니다.

## 원칙

- MIT와 상업적 사용을 포함한 영구 무료 약속을 지킵니다.
- 유료 티어, 라이선스 키, 좌석·LoC 제한, 텔레메트리, 로그인을 추가하지 않습니다.
- 삭제 가능 판정이나 자동 삭제를 추가하지 않습니다.
- 모든 finding에 근거와 분석 한계를 보존합니다.
- `package:analyzer` import는 `lib/src/index/` 안에만 둡니다.
- 사용자 출력은 영어, 코드 주석은 한국어로 씁니다.

## 개발

Dart 3.11 이상이 필요합니다.

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
tool/verify-false-positive-corpus.sh
tool/check-coverage.sh
tool/check-analyzer-boundary.sh
tool/verify-cli-contract.sh
tool/verify-global-activation.sh
```

동작 변경은 실패하는 테스트를 먼저 확인한 뒤 최소 구현으로 통과시킵니다. 오탐 수정은
양방향 fixture를 먼저 추가합니다. Conventional Commits를 쓰고 `main`에 직접 커밋하지
않습니다. 커밋 본문에는 변경 내용보다 변경 이유를 한국어로 적습니다.

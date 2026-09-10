/// 같은 파일(라이브러리) 안에서만 쓰는 공개 헬퍼 — 관측상 라이브러리 비공개로
/// 좁혀도 참조가 깨지지 않는다(`--report-redundant-public` 검증 입력).
int internalScale(int value) => value * 2;

/// main에서 호출되는 공개 진입 — 다른 라이브러리가 쓰므로 좁히면 깨진다.
int runInternal(int value) => internalScale(value);

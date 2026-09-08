/// 그래프 밖의 실행 계약이나 사용자 지시 때문에 선언을 도달성 루트로
/// 보존하는 이유다.
enum RetentionReason {
  /// 패키지의 `lib/`, `bin/`, `example/` 아래 실행 진입점이다.
  mainEntryPoint,

  /// 패키지의 대표 라이브러리가 외부 소비자에게 공개하는 선언이다.
  publicApi,

  /// 프레임워크나 언어 런타임이 상위 계약을 통해 호출하는 재정의다.
  overrideContract,

  /// 테스트 또는 테스트 전용 API에서 시작하는 참조다.
  visibleForTesting,

  /// 생성 코드가 사용자 선언을 참조하는 출발점이다.
  generatedCode,

  /// VM이나 네이티브 코드가 이름으로 호출할 수 있다.
  vmEntryPoint,

  /// Flutter 플러그인 manifest가 등록 클래스를 이름으로 가리킨다.
  pluginEntryPoint,

  /// `// dartograph:ignore` 인라인 주석이 바로 위 선언의 보고 억제를 지시한다.
  inlineIgnore,
}

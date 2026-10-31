/// 인덱스의 테스트 보존과 분석 범위가 같은 프로젝트 상대 소스를 판정하게 한다.
bool isTestSourceUri(String? source) =>
    source != null &&
    const [
      'project:test/',
      'project:integration_test/',
      'project:example/test/',
      'project:example/integration_test/',
    ].any(source.startsWith);

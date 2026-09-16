/// `deps`가 보고하는 pubspec 의존 위생 발견이다.
///
/// 발견은 검토 후보와 근거이며 삭제 지시가 아니다 — 도구 인지(실행 파일·
/// builder·lint include·analyzer plugin)는 관측된 사실만 반영하고, 그 밖의
/// 사용 채널(런타임 로딩·생성 코드 경유)은 보이지 않는다.
final class DependencyFinding {
  /// 발견 사실을 보존한다.
  const DependencyFinding({
    required this.name,
    required this.kind,
    required this.reason,
    this.sources = const [],
  });

  /// pubspec 또는 import 지시문에 나온 패키지 이름이다.
  final String name;

  /// 발견 종류다. 아래 네 가지 중 하나다.
  ///
  /// - `unused-dependency`: `dependencies`에 선언됐지만 어떤 분석 대상 소스도
  ///   `package:` 지시문으로 참조하지 않고 도구 계약도 확인되지 않았다.
  /// - `unused-dev-dependency`: `dev_dependencies`에 같은 관측이다.
  /// - `dev-dependency-in-lib`: `dev_dependencies` 선언이 `lib/` 안 소스에서
  ///   참조됐다 — 게시된 패키지의 소비자에게 그 의존은 없다.
  /// - `undeclared-dependency`: `package:` 지시문이 참조하지만 어느 의존 섹션에도
  ///   선언되지 않았다(전이 의존을 통해 해석될 수 있다).
  final String kind;

  /// 발견을 만든 관찰이다.
  final String reason;

  /// 그 이름을 참조하는 소스 ID(`project:…`) 목록이다. 미사용 발견은 비어 있다.
  final List<String> sources;

  /// 키와 목록 순서가 안정적인 JSON 값이다.
  Map<String, Object?> toJson() => {
    'kind': kind,
    'name': name,
    'reason': reason,
    'sources': sources,
  };
}

/// pubspec 선언과 관측된 `package:` 참조를 대조하는 감사다.
final class DependencyAudit {
  /// 선언·관측을 대조해 발견 목록을 결정적 순서로 돌려준다.
  ///
  /// [toolLike]는 실행 파일·builder·lint include·analyzer plugin 계약이 확인된
  /// 패키지 이름이다 — 그 선언은 import가 없어도 사용 중으로 본다.
  List<DependencyFinding> audit({
    String? packageName,
    required List<String> dependencies,
    required List<String> devDependencies,
    required List<String> dependencyOverrides,
    required Map<String, List<String>> packageImports,
    required Set<String> toolLike,
  }) {
    final findings = <DependencyFinding>[];
    final declared = {
      ...dependencies,
      ...devDependencies,
      ...dependencyOverrides,
    };
    for (final name in dependencies) {
      if (packageImports.containsKey(name) || toolLike.contains(name)) continue;
      findings.add(
        DependencyFinding(
          name: name,
          kind: 'unused-dependency',
          reason:
              'declared in dependencies but no package: import or export '
              'references it',
        ),
      );
    }
    for (final name in devDependencies) {
      if (packageImports.containsKey(name) || toolLike.contains(name)) continue;
      findings.add(
        DependencyFinding(
          name: name,
          kind: 'unused-dev-dependency',
          reason:
              'declared in dev_dependencies but no package: import or export '
              'references it',
        ),
      );
    }
    for (final name in devDependencies) {
      final importers = packageImports[name];
      if (importers == null) continue;
      final production = importers
          .where((source) => source.startsWith('project:lib/'))
          .toList();
      if (production.isEmpty) continue;
      findings.add(
        DependencyFinding(
          name: name,
          kind: 'dev-dependency-in-lib',
          reason:
              'declared in dev_dependencies but referenced by lib/ sources; '
              'consumers of the published package will not have it',
          sources: production,
        ),
      );
    }
    final imported = packageImports.keys.toList()..sort();
    for (final name in imported) {
      if (name == packageName || declared.contains(name)) continue;
      if (_isFederatedSibling(name, declared)) continue;
      findings.add(
        DependencyFinding(
          name: name,
          kind: 'undeclared-dependency',
          reason:
              'imported or exported via package: but not declared in '
              'dependencies, dev_dependencies, or dependency_overrides',
          sources: packageImports[name]!,
        ),
      );
    }
    findings.sort((a, b) => '${a.kind}$a.name'.compareTo('${b.kind}$b.name'));
    return findings;
  }

  /// [name]이 선언된 federated plugin의 플랫폼 구현 패키지인지 본다.
  ///
  /// `url_launcher`를 선언한 프로젝트가 `url_launcher_android`를 import하는
  /// 것은 endorsed impl에 대한 의도된 직접 참조다 — 미선언으로 보지 않는다.
  /// 접미가 플랫폼 구현체 계약(`_platform_interface` 포함)일 때만 적용한다.
  bool _isFederatedSibling(String name, Set<String> declared) {
    for (final suffix in _federatedSuffixes) {
      if (!name.endsWith(suffix)) continue;
      if (declared.contains(name.substring(0, name.length - suffix.length))) {
        return true;
      }
    }
    return false;
  }
}

/// federated plugin의 플랫폼 구현·인터페이스 접미다.
const _federatedSuffixes = [
  '_android',
  '_ios',
  '_linux',
  '_macos',
  '_platform_interface',
  '_web',
  '_windows',
];

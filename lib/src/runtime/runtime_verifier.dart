import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'runtime_facts.dart';

/// 사실 하나에 대한 판정이다.
enum RuntimeVerdict {
  /// 이 환경에 값·경로가 있다.
  present,

  /// 값이 없지만 코드가 명시한 기본값으로 동작한다.
  defaulted,

  /// 값이 없고 기본값도 없다.
  missing,

  /// 정적으로 판정할 수 없다(사유를 함께 남긴다).
  unverifiable,
}

/// 판정과 그 근거다.
final class VerifiedRuntimeFact {
  /// 판정 결과를 만든다.
  const VerifiedRuntimeFact({
    required this.fact,
    required this.verdict,
    required this.evidence,
  });

  /// 판정 대상 사실이다.
  final RuntimeFact fact;

  /// 판정이다. [RuntimeVerdict.unverifiable]은 이 형에 오지 않는다.
  final RuntimeVerdict verdict;

  /// 어느 입력으로 판정했는지 나타내는 근거다. 환경변수·dart-define의 값은
  /// 값 자체가 민감할 수 있으므로 싣지 않고 존재만 적는다.
  final String evidence;

  /// 보고서 JSON 표현이다. 키는 사전순으로 고정한다.
  Map<String, Object> toJson() => {
    'channel': fact.channel.key,
    'column': fact.column,
    'detail': fact.detail,
    'evidence': evidence,
    'id': fact.id,
    'kind': fact.kind.key,
    'line': fact.line,
    'name': fact.name,
    'source': fact.source,
    'verdict': verdict.name,
  };
}

/// 판정하지 못한 사실과 실패 사유다.
final class UnverifiedRuntimeFact {
  /// 사유와 함께 미판정 사실을 만든다.
  const UnverifiedRuntimeFact({required this.fact, required this.reason});

  /// 미판정 사실이다.
  final RuntimeFact fact;

  /// 판정하지 못한 이유다.
  final String reason;

  /// 보고서 JSON 표현이다. 키는 사전순으로 고정한다.
  Map<String, Object> toJson() => {
    'channel': fact.channel.key,
    'column': fact.column,
    'kind': fact.kind.key,
    'line': fact.line,
    'name': fact.name,
    'reason': reason,
    'source': fact.source,
  };
}

/// 위험도 요인 하나다.
final class RuntimeRiskFactor {
  /// 요인을 만든다.
  const RuntimeRiskFactor({
    required this.name,
    required this.weight,
    required this.detail,
  });

  /// 안정적인 요인 이름이다.
  final String name;

  /// 점수 기여도다.
  final int weight;

  /// 사람이 읽는 설명이다.
  final String detail;

  /// 보고서 JSON 표현이다.
  Map<String, Object> toJson() => {
    'detail': detail,
    'name': name,
    'weight': weight,
  };
}

/// 위험도 점수와 등급이다.
final class RuntimeRisk {
  /// 위험도를 만든다.
  const RuntimeRisk({
    required this.score,
    required this.level,
    required this.factors,
  });

  /// 0–100 점수다.
  final int score;

  /// `none`·`low`·`medium`·`high` 중 하나다.
  final String level;

  /// 점수를 만든 요인들이다.
  final List<RuntimeRiskFactor> factors;

  /// 보고서 JSON 표현이다.
  Map<String, Object> toJson() => {
    'factors': factors.map((factor) => factor.toJson()).toList(),
    'level': level,
    'score': score,
  };
}

/// `--limit`으로 생략한 항목 수다.
final class RuntimeTruncation {
  /// 생략 수를 담는다.
  const RuntimeTruncation({
    required this.detected,
    required this.verified,
    required this.unverified,
  });

  /// `detected`에서 생략한 사실 수다.
  final int detected;

  /// `present`·`defaulted`·`missing`에서 생략한 항목 수다.
  final int verified;

  /// `unverified`에서 생략한 항목 수다.
  final int unverified;

  /// 생략이 없었는지 여부다.
  bool get isEmpty => detected == 0 && verified == 0 && unverified == 0;

  /// 보고서 JSON 표현이다.
  Map<String, Object> toJson() => {
    'detected': detected,
    'unverified': unverified,
    'verified': verified,
  };
}

/// 런타임 의존성 보고서(`runtime-report` version 1)다.
final class RuntimeReport {
  /// 보고서를 만든다.
  const RuntimeReport({
    required this.detected,
    required this.present,
    required this.defaulted,
    required this.missing,
    required this.unverified,
    required this.risk,
    required this.truncated,
    required this.execution,
    required this.limitations,
    required this.verified,
  });

  /// 카테고리별 탐지 사실이다. 다섯 카테고리 키가 항상 모두 있다.
  final Map<RuntimeFactKind, List<RuntimeFact>> detected;

  /// 충족된 사실이다.
  final List<VerifiedRuntimeFact> present;

  /// 기본값으로 동작하는 사실이다.
  final List<VerifiedRuntimeFact> defaulted;

  /// 충족되지 않은 사실이다.
  final List<VerifiedRuntimeFact> missing;

  /// 판정하지 못한 사실이다.
  final List<UnverifiedRuntimeFact> unverified;

  /// 위험도다.
  final RuntimeRisk risk;

  /// 생략 수다.
  final RuntimeTruncation truncated;

  /// 실행 증거다. `--execute`를 쓰지 않았으면 null이다.
  final RuntimeExecution? execution;

  /// 정적 탐지의 한계다(중복 제거·정렬된 상태).
  final List<String> limitations;

  /// 검증을 수행했는지 여부다. false면 판정 목록들이 비어 있다.
  final bool verified;
}

/// 탐지 사실을 이 환경에 대해 판정한다.
///
/// 파일 시스템은 [RuntimeFileSystem] 경계로만 관측하므로 판정 규칙 자체는
/// 순수 함수다. 값 자체(환경변수·dart-define의 값)는 근거에 싣지 않는다 —
/// 보고서가 CI 로그·아티팩트로 복사될 때 비밀이 따라가지 않게 하기 위해서다.
abstract final class RuntimeVerifier {
  /// 정적 탐지로는 닿을 수 없는 한계를 미리 선언한다.
  ///
  /// 보고서에도 같은 문구가 실린다. 판정 결과만 보고 "없다"고 단정하지 않도록
  /// 탐지기와 검증기의 공백을 같은 자리에서 밝힌다.
  static const detectionLimitations = <String>[
    'asset-variants: Flutter asset variants, flavors and asset transformers are '
        'not modeled',
    'computed-targets: entries named $runtimeComputedName come from '
        'non-literal expressions and cannot be resolved statically',
    'conditional-configuration: only the analyzer-selected conditional import '
        'configuration is analyzed',
    'environment-values: variable values are never printed; only presence is '
        'reported',
    'external-network: external URLs and HttpClient targets are never probed',
    'native-libraries: a bare native library name is resolved by the OS dynamic '
        'loader, not by the package root; a library named by path is checked '
        'for existence in the package, not for a loadable ABI',
    'optional-reads: a missing path may be optional at runtime; the report does '
        'not distinguish required from optional reads',
    'pubspec-fonts: font declarations in pubspec.yaml are not scanned',
    'reflection: dart:mirrors, Function.apply and Isolate.spawn can reach code '
        'without a static reference',
    'relative-paths: a relative URI or path is checked against the package '
        'root; the runtime may resolve it against the script URI or the working '
        'directory',
    'source-scope: only the standard source directories (lib, bin, test, '
        'example, integration_test) are analyzed',
    'static-endpoints: only http(s) literals written at a Uri.parse or network '
        'call site are reported as external; destinations assembled at runtime, '
        'read from configuration, or passed through variables are not detected',
    'string-interpolation: a key or path built by interpolation is reported as '
        '$runtimeComputedName, not guessed',
  ];

  /// [facts]를 [inputs]·[fileSystem]에 대해 판정하고 보고서를 조립한다.
  ///
  /// [limit]은 각 목록의 보고 항목 수 상한이다. 위험도는 상한을 적용하기 전의
  /// 전체 집합으로 계산한다 — `--limit`이 종료 코드를 바꾸면 게이트가 아니다.
  static RuntimeReport analyze({
    required List<RuntimeFact> facts,
    required RuntimeInputs inputs,
    required RuntimeFileSystem fileSystem,
    RuntimeExecution? execution,
    int? limit,
    bool verify = true,
  }) {
    final limitations = <String>[
      ...detectionLimitations,
      if (inputs.environmentFromProcess)
        'environment-source: verification used the caller process environment; '
            'results depend on the shell that ran the command'
      else
        'environment-source: verification used only the values given with '
            '--env (hermetic; the process environment was ignored)',
      if (!verify)
        'verification-disabled: --no-verify detected facts without judging '
            'them; no presence check and no risk score was produced',
      if (execution != null && !execution.unresolved)
        'execute-runs-code: --execute ran the entrypoint as a child process; '
            'the reported exit code is the only containment',
      if (execution != null && !execution.unresolved && execution.timedOut)
        'execute-process-scope: the timed-out run was killed by PID only; '
            'descendant processes may have outlived the timeout',
      if (execution != null && execution.unresolved)
        'execute-unresolved: --execute ran nothing because the dart executable '
            'could not be resolved; the reason is reported in execution.reason',
    ];

    final judgements = verify
        ? [for (final fact in facts) _judge(fact, inputs, fileSystem)]
        : const <_Judgement>[];

    final present = <VerifiedRuntimeFact>[];
    final defaulted = <VerifiedRuntimeFact>[];
    final missing = <VerifiedRuntimeFact>[];
    final unverified = <UnverifiedRuntimeFact>[];
    for (final judgement in judgements) {
      switch (judgement.verdict) {
        case RuntimeVerdict.present:
          present.add(
            VerifiedRuntimeFact(
              fact: judgement.fact,
              verdict: RuntimeVerdict.present,
              evidence: judgement.evidence,
            ),
          );
        case RuntimeVerdict.defaulted:
          defaulted.add(
            VerifiedRuntimeFact(
              fact: judgement.fact,
              verdict: RuntimeVerdict.defaulted,
              evidence: judgement.evidence,
            ),
          );
        case RuntimeVerdict.missing:
          missing.add(
            VerifiedRuntimeFact(
              fact: judgement.fact,
              verdict: RuntimeVerdict.missing,
              evidence: judgement.evidence,
            ),
          );
        case RuntimeVerdict.unverifiable:
          unverified.add(
            UnverifiedRuntimeFact(
              fact: judgement.fact,
              reason: judgement.evidence,
            ),
          );
      }
    }

    final externalCount = unverified
        .where((item) => item.fact.channel == RuntimeFactChannel.externalUrl)
        .length;
    final risk = _risk(
      missingCount: missing.length,
      unverifiedCount: unverified.length - externalCount,
      externalCount: externalCount,
      executionFailed:
          execution != null && !execution.unresolved && !execution.ok,
    );

    // 정렬은 검증기가 한다 — 판정 순서가 탐지 순서와 달라도 출력은 위치순이다.
    present.sort(_compareVerified);
    defaulted.sort(_compareVerified);
    missing.sort(_compareVerified);
    unverified.sort((a, b) => compareRuntimeFacts(a.fact, b.fact));

    final detected = {
      for (final kind in RuntimeFactKind.values)
        kind: facts.where((fact) => fact.kind == kind).toList(),
    };
    final truncated = _truncate(
      detected: detected,
      present: present,
      defaulted: defaulted,
      missing: missing,
      unverified: unverified,
      limit: limit,
    );

    return RuntimeReport(
      detected: detected,
      present: present,
      defaulted: defaulted,
      missing: missing,
      unverified: unverified,
      risk: risk,
      truncated: truncated,
      execution: execution,
      limitations: limitations.toSet().toList()..sort(),
      verified: verify,
    );
  }

  /// 보고 항목 수 상한을 적용하고 생략 수를 계산한다.
  static RuntimeTruncation _truncate({
    required Map<RuntimeFactKind, List<RuntimeFact>> detected,
    required List<VerifiedRuntimeFact> present,
    required List<VerifiedRuntimeFact> defaulted,
    required List<VerifiedRuntimeFact> missing,
    required List<UnverifiedRuntimeFact> unverified,
    required int? limit,
  }) {
    if (limit == null) {
      return const RuntimeTruncation(detected: 0, verified: 0, unverified: 0);
    }
    var detectedOmitted = 0;
    for (final entry in detected.entries) {
      if (entry.value.length <= limit) continue;
      detectedOmitted += entry.value.length - limit;
      detected[entry.key] = entry.value.take(limit).toList();
    }
    var verifiedOmitted = 0;
    for (final list in [present, defaulted, missing]) {
      if (list.length <= limit) continue;
      verifiedOmitted += list.length - limit;
      list.removeRange(limit, list.length);
    }
    var unverifiedOmitted = 0;
    if (unverified.length > limit) {
      unverifiedOmitted = unverified.length - limit;
      unverified.removeRange(limit, unverified.length);
    }
    return RuntimeTruncation(
      detected: detectedOmitted,
      verified: verifiedOmitted,
      unverified: unverifiedOmitted,
    );
  }

  static int _compareVerified(VerifiedRuntimeFact a, VerifiedRuntimeFact b) =>
      compareRuntimeFacts(a.fact, b.fact);

  /// 위험도를 요인 합으로 계산한다.
  ///
  /// 요인은 겹치지 않는다: 미충족, 미판정(외부 자원 제외), 외부 자원, 실행 실패가
  /// 각각 한 번씩만 점수에 들어간다. 미판정과 외부 자원을 나눠 세는 이유는
  /// 외부 URL이 미판정 목록을 채우더라도 그 수가 "정적으로 알 수 없는 코드"의
  /// 수를 부풀리지 않게 하기 위해서다.
  static RuntimeRisk _risk({
    required int missingCount,
    required int unverifiedCount,
    required int externalCount,
    required bool executionFailed,
  }) {
    final factors = <RuntimeRiskFactor>[
      if (missingCount > 0)
        RuntimeRiskFactor(
          name: 'missing-inputs',
          weight: math.min(missingCount * 12, 72),
          detail:
              '$missingCount detected runtime input(s) are not satisfied in '
              'this environment',
        ),
      if (unverifiedCount > 0)
        RuntimeRiskFactor(
          name: 'unverified-facts',
          weight: math.min(unverifiedCount * 5, 24),
          detail:
              '$unverifiedCount fact(s) cannot be judged without running the '
              'program',
        ),
      if (externalCount > 0)
        RuntimeRiskFactor(
          name: 'external-resources',
          weight: math.min(externalCount * 4, 16),
          detail:
              '$externalCount external resource(s) cannot be probed offline',
        ),
      if (executionFailed)
        const RuntimeRiskFactor(
          name: 'execution-failed',
          weight: 30,
          detail: 'the --execute entrypoint did not exit successfully',
        ),
    ];
    final score = math.min(
      100,
      factors.fold<int>(0, (sum, factor) => sum + factor.weight),
    );
    return RuntimeRisk(score: score, level: _level(score), factors: factors);
  }

  /// 점수를 `--fail-on`·보고서가 쓰는 등급으로 바꾼다.
  static String _level(int score) {
    if (score >= 50) return 'high';
    if (score >= 20) return 'medium';
    if (score > 0) return 'low';
    return 'none';
  }

  /// 사실 하나를 판정한다.
  static _Judgement _judge(
    RuntimeFact fact,
    RuntimeInputs inputs,
    RuntimeFileSystem fileSystem,
  ) {
    final declared = fact.unverifiableReason;
    if (declared != null) {
      return _Judgement(fact, RuntimeVerdict.unverifiable, declared);
    }
    if (!fact.literal) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'computed-target: the target is not a literal value, so verification '
        'cannot check it',
      );
    }
    switch (fact.channel) {
      case RuntimeFactChannel.dartDefine:
        return _judgeDartDefine(fact, inputs);
      case RuntimeFactChannel.processEnvironment:
        return _judgeEnvironment(fact, inputs);
      case RuntimeFactChannel.filePath:
      case RuntimeFactChannel.directoryPath:
      case RuntimeFactChannel.assetBundle:
        return _judgePath(fact, fileSystem);
      case RuntimeFactChannel.executable:
        return _judgeExecutable(fact, inputs, fileSystem);
      case RuntimeFactChannel.uri:
        return _judgeUri(fact, inputs, fileSystem);
      case RuntimeFactChannel.reflection:
        return _Judgement(
          fact,
          RuntimeVerdict.unverifiable,
          'reflection-target: only the call shape is known, not the code it '
          'reaches',
        );
      case RuntimeFactChannel.externalUrl:
        return _Judgement(
          fact,
          RuntimeVerdict.unverifiable,
          'external-resource: verification performs no network access',
        );
      case RuntimeFactChannel.nativeLibrary:
        return _judgeNativeLibrary(fact, fileSystem);
    }
  }

  /// `DynamicLibrary.open` 대상을 판정한다.
  ///
  /// 경로로 지정한 대상은 패키지 루트(또는 절대경로) 기준으로 존재를 확인한다.
  /// 경로가 없으면 맨 이름이라 OS 동적 로더가 루트 밖에서 찾으므로 검증기가
  /// 판정할 수 없다 — 탐지 단계가 붙인 사유를 그대로 쓴다.
  static _Judgement _judgeNativeLibrary(
    RuntimeFact fact,
    RuntimeFileSystem fileSystem,
  ) {
    final candidate = fact.path;
    if (candidate == null) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'bare-library-name: the dynamic loader resolves "${fact.name}" '
        'outside the package root',
      );
    }
    return switch (fileSystem.state(candidate)) {
      RuntimePathState.file => _Judgement(
        fact,
        RuntimeVerdict.present,
        'native library exists: $candidate',
      ),
      RuntimePathState.directory => _Judgement(
        fact,
        RuntimeVerdict.missing,
        'a directory exists at $candidate, not a native library',
      ),
      RuntimePathState.missing => _Judgement(
        fact,
        RuntimeVerdict.missing,
        'native library not found: $candidate',
      ),
    };
  }

  static _Judgement _judgeDartDefine(RuntimeFact fact, RuntimeInputs inputs) {
    if (inputs.dartDefines.containsKey(fact.name)) {
      return _Judgement(
        fact,
        RuntimeVerdict.present,
        '--dart-define ${fact.name}',
      );
    }
    final defaultValue = fact.defaultValue;
    if (defaultValue != null) {
      return _Judgement(
        fact,
        RuntimeVerdict.defaulted,
        'default value "$defaultValue"',
      );
    }
    return _Judgement(
      fact,
      RuntimeVerdict.missing,
      'not provided by --dart-define and no default',
    );
  }

  static _Judgement _judgeEnvironment(RuntimeFact fact, RuntimeInputs inputs) {
    if (inputs.environment.containsKey(fact.name)) {
      return _Judgement(
        fact,
        RuntimeVerdict.present,
        inputs.environmentFromProcess
            ? 'process environment'
            : '--env ${fact.name}',
      );
    }
    final defaultValue = fact.defaultValue;
    if (defaultValue != null) {
      return _Judgement(
        fact,
        RuntimeVerdict.defaulted,
        'default value "$defaultValue"',
      );
    }
    return _Judgement(
      fact,
      RuntimeVerdict.missing,
      inputs.environmentFromProcess
          ? 'not present in the process environment'
          : 'not provided by --env',
    );
  }

  static _Judgement _judgePath(RuntimeFact fact, RuntimeFileSystem fileSystem) {
    final candidate = fact.path;
    if (candidate == null) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'no-path: the fact carries no checkable path',
      );
    }
    final state = fileSystem.state(candidate);
    switch (fact.channel) {
      case RuntimeFactChannel.filePath:
        return switch (state) {
          RuntimePathState.file => _Judgement(
            fact,
            RuntimeVerdict.present,
            'file exists: $candidate',
          ),
          RuntimePathState.directory => _Judgement(
            fact,
            RuntimeVerdict.missing,
            'a directory exists at $candidate, not a file',
          ),
          RuntimePathState.missing => _Judgement(
            fact,
            RuntimeVerdict.missing,
            'file not found: $candidate',
          ),
        };
      case RuntimeFactChannel.directoryPath:
        return switch (state) {
          RuntimePathState.directory => _Judgement(
            fact,
            RuntimeVerdict.present,
            'directory exists: $candidate',
          ),
          RuntimePathState.file => _Judgement(
            fact,
            RuntimeVerdict.missing,
            'a file exists at $candidate, not a directory',
          ),
          RuntimePathState.missing => _Judgement(
            fact,
            RuntimeVerdict.missing,
            'directory not found: $candidate',
          ),
        };
      default:
        return switch (state) {
          RuntimePathState.file => _Judgement(
            fact,
            RuntimeVerdict.present,
            'asset file exists: $candidate',
          ),
          RuntimePathState.directory => _Judgement(
            fact,
            RuntimeVerdict.present,
            'asset directory exists: $candidate',
          ),
          RuntimePathState.missing => _Judgement(
            fact,
            RuntimeVerdict.missing,
            'asset not found: $candidate',
          ),
        };
    }
  }

  static _Judgement _judgeExecutable(
    RuntimeFact fact,
    RuntimeInputs inputs,
    RuntimeFileSystem fileSystem,
  ) {
    final candidate = fact.path;
    if (candidate == null) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'no-path: the fact carries no checkable path',
      );
    }
    final isPath =
        p.isAbsolute(candidate) ||
        candidate.contains('/') ||
        candidate.contains(r'\');
    if (isPath) {
      final state = fileSystem.state(candidate);
      if (state != RuntimePathState.file) {
        return _Judgement(
          fact,
          RuntimeVerdict.missing,
          state == RuntimePathState.directory
              ? 'a directory exists at $candidate, not an executable'
              : 'file not found: $candidate',
        );
      }
      if (!fileSystem.executableAt(candidate)) {
        return _Judgement(
          fact,
          RuntimeVerdict.missing,
          'file exists but is not executable: $candidate',
        );
      }
      return _Judgement(
        fact,
        RuntimeVerdict.present,
        'executable file: $candidate',
      );
    }
    final pathValue = inputs.environment['PATH'];
    if (pathValue == null || pathValue.isEmpty) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'path-not-provided: PATH is unavailable in the verification '
        'environment, so "$candidate" cannot be looked up',
      );
    }
    final separators = inputs.windows ? ';' : ':';
    final suffixes = inputs.windows
        ? const ['', '.exe', '.bat', '.cmd']
        : const [''];
    for (final directory in pathValue.split(separators)) {
      if (directory.isEmpty) continue;
      for (final suffix in suffixes) {
        if (fileSystem.executableAt(p.join(directory, '$candidate$suffix'))) {
          return _Judgement(
            fact,
            RuntimeVerdict.present,
            'executable found on PATH',
          );
        }
      }
    }
    return _Judgement(
      fact,
      RuntimeVerdict.missing,
      'no executable named $candidate on PATH',
    );
  }

  static _Judgement _judgeUri(
    RuntimeFact fact,
    RuntimeInputs inputs,
    RuntimeFileSystem fileSystem,
  ) {
    final candidate = fact.path;
    if (candidate == null) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'no-path: the fact carries no checkable URI',
      );
    }
    final uri = Uri.tryParse(candidate);
    if (uri == null) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'invalid-uri: "$candidate" is not a valid URI',
      );
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'remote-uri: verification performs no network access',
      );
    }
    if (uri.scheme == 'file') {
      final String path;
      try {
        path = uri.toFilePath(windows: inputs.windows);
      } on UnsupportedError {
        // query·fragment가 붙은 file: URI 등 — 경로로 환원할 수 없다.
        return _Judgement(
          fact,
          RuntimeVerdict.unverifiable,
          'invalid-uri: "$candidate" cannot be reduced to a file path',
        );
      }
      final state = fileSystem.state(path);
      return switch (state) {
        RuntimePathState.file => _Judgement(
          fact,
          RuntimeVerdict.present,
          'file exists: $path',
        ),
        RuntimePathState.directory => _Judgement(
          fact,
          RuntimeVerdict.missing,
          'a directory exists at $path, not a file',
        ),
        RuntimePathState.missing => _Judgement(
          fact,
          RuntimeVerdict.missing,
          'file not found: $path',
        ),
      };
    }
    if (uri.scheme.isNotEmpty) {
      return _Judgement(
        fact,
        RuntimeVerdict.unverifiable,
        'uri-scheme: the scheme "${uri.scheme}" is resolved outside the '
        'package root',
      );
    }
    final state = fileSystem.state(candidate);
    return switch (state) {
      RuntimePathState.file => _Judgement(
        fact,
        RuntimeVerdict.present,
        'file exists: $candidate',
      ),
      RuntimePathState.directory => _Judgement(
        fact,
        RuntimeVerdict.missing,
        'a directory exists at $candidate, not a file',
      ),
      RuntimePathState.missing => _Judgement(
        fact,
        RuntimeVerdict.missing,
        'file not found: $candidate',
      ),
    };
  }
}

/// 판정 중간 결과다.
final class _Judgement {
  const _Judgement(this.fact, this.verdict, this.evidence);

  final RuntimeFact fact;
  final RuntimeVerdict verdict;
  final String evidence;
}

/// dart:io로 실제 파일 시스템을 관측하는 기본 구현이다.
final class LocalRuntimeFileSystem implements RuntimeFileSystem {
  /// [rootPath]를 상대 경로의 기준으로 삼는다.
  LocalRuntimeFileSystem(this.rootPath);

  /// 상대 경로를 해석할 패키지 루트다.
  final String rootPath;

  @override
  RuntimePathState state(String path) {
    if (path.isEmpty) return RuntimePathState.missing;
    final absolute = p.isAbsolute(path) ? path : p.join(rootPath, path);
    return switch (FileSystemEntity.typeSync(absolute)) {
      FileSystemEntityType.file => RuntimePathState.file,
      FileSystemEntityType.directory => RuntimePathState.directory,
      _ => RuntimePathState.missing,
    };
  }

  @override
  bool executableAt(String path) {
    if (path.isEmpty) return false;
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    if (Platform.isWindows) return true;
    // 0o111: 소유자·그룹·기타 실행 비트 중 하나라도 서 있으면 실행 가능하다.
    return stat.mode & 0x49 != 0;
  }
}

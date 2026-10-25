part of 'dartograph_cli.dart';

/// 준비된 두 checkout의 실제 내용 변화에 각각의 그래프를 귀속한다.
Future<int> _runImpactChange(
  String beforeRoot,
  String afterRoot,
  StringSink output,
  StringSink error,
  IndexPackage indexPackage,
  ImpactFormat format,
  int? depth,
  int? limit,
  int threshold,
  List<String> failedItems,
) async {
  if (!const {
    ImpactFormat.text,
    ImpactFormat.json,
    ImpactFormat.markdown,
  }.contains(format)) {
    error.writeln(
      'Two-snapshot impact supports text, json, or markdown; use the separated current.tests list for test candidates.',
    );
    return ExitStatus.usage.code;
  }
  final timer = Stopwatch()..start();
  final beforeInput = await captureAnalysisInputs(beforeRoot);
  final before = await indexPackage(beforeRoot);
  final beforeCheck = await captureAnalysisInputs(beforeRoot);
  final afterInput = await captureAnalysisInputs(afterRoot);
  final after = await indexPackage(afterRoot);
  final afterCheck = await captureAnalysisInputs(afterRoot);
  final changed =
      {...beforeInput.projectFiles.keys, ...afterInput.projectFiles.keys}
          .where(
            (path) =>
                beforeInput.projectFiles[path] != afterInput.projectFiles[path],
          )
          .toList()
        ..sort();
  final historical = ImpactAnalysis.analyze(
    before.graph.snapshot(),
    changedSources: {
      for (final path in changed)
        if (beforeInput.projectFiles.containsKey(path)) 'project:$path',
    },
    maxDepth: depth,
    limit: limit,
  );
  final current = ImpactAnalysis.analyze(
    after.graph.snapshot(),
    changedSources: {
      for (final path in changed)
        if (afterInput.projectFiles.containsKey(path)) 'project:$path',
    },
    maxDepth: depth,
    limit: limit,
  );
  final historicalInput = await _impactInput(
    beforeRoot,
    beforeInput,
    beforeCheck,
    'prepared-before-checkout',
  );
  final currentInput = await _impactInput(
    afterRoot,
    afterInput,
    afterCheck,
    'prepared-current-checkout',
  );
  final stale =
      historicalInput['freshness'] == 'stale' ||
      currentInput['freshness'] == 'stale';
  final limitations = <String>[
    'static-candidates-only: no result proves safety, predicts test failures, or authorizes skipping tests',
    'file-wide-seeds: all declarations in changed files are selected; changed lines are not isolated',
    'separate-revisions: historical candidates may no longer exist; paths never combine before and current edges',
    'rename-as-delete-add: old and new file/symbol identities are preserved independently, not inferred as equivalent',
    'input-scope: project Dart/configuration files and cache resolution inputs are content-checked; content-locked dependencies, hidden imports, external/runtime state are not fully verified',
    if (changed.any((path) => !path.endsWith('.dart')))
      'configuration-change: changed non-Dart inputs are listed but their runtime propagation is not inferred',
    if (stale)
      'input-changed-during-analysis: source or configuration changed while indexing; rerun',
  ];
  List<String> limitsFor(AnalyzerGraphResult indexed, ImpactReport report) => [
    ...limitations,
    ..._limitations(indexed),
    if (report.unattributedSources.isNotEmpty)
      'changed-sources-without-node: some changed inputs are outside the observed graph; inspect changed.unattributedSources',
  ];
  final beforeRendered = ImpactReporter.render(
    ImpactFormat.json,
    historical,
    limitations: limitsFor(before, historical),
    input: historicalInput,
  );
  final afterRendered = ImpactReporter.render(
    ImpactFormat.json,
    current,
    limitations: limitsFor(after, current),
    input: currentInput,
  );
  timer.stop();
  if (format == ImpactFormat.json) {
    output.writeln(
      jsonEncode({
        'version': 1,
        'mode': 'before-current',
        'status': stale ? 'stale' : 'incomplete',
        'changes': [
          for (final path in changed)
            {
              'path': path,
              'kind': !beforeInput.projectFiles.containsKey(path)
                  ? 'added'
                  : !afterInput.projectFiles.containsKey(path)
                  ? 'deleted'
                  : 'modified',
              'beforeHash': beforeInput.projectFiles[path],
              'currentHash': afterInput.projectFiles[path],
              'seedReason': path.endsWith('.dart')
                  ? 'changed-file-content'
                  : 'changed-configuration',
            },
        ],
        'historical': jsonDecode(beforeRendered),
        'current': jsonDecode(afterRendered),
        'limitations': limitations,
        'cost': {
          'preparationAndAnalysisMilliseconds': timer.elapsedMilliseconds,
        },
      }),
    );
  } else {
    output.writeln(
      format == ImpactFormat.markdown
          ? '# Historical impact'
          : 'Historical impact (before snapshot):',
    );
    output.write(
      ImpactReporter.render(
        format,
        historical,
        limitations: limitsFor(before, historical),
        input: historicalInput,
      ),
    );
    output.writeln(
      format == ImpactFormat.markdown
          ? '# Current impact'
          : 'Current impact (current snapshot):',
    );
    output.write(
      ImpactReporter.render(
        format,
        current,
        limitations: limitsFor(after, current),
        input: currentInput,
      ),
    );
  }
  failedItems.addAll(
    [...historical.impacted, ...current.impacted].map((item) => item.id),
  );
  if (threshold > 0 &&
      (_riskRank(historical.risk.level) >= threshold ||
          _riskRank(current.risk.level) >= threshold)) {
    return ExitStatus.findings.code;
  }
  return ExitStatus.success.code;
}

Future<Map<String, Object?>> _impactInput(
  String root,
  AnalysisInputCapture capture,
  AnalysisInputCapture check,
  String origin,
) async {
  String? revision;
  try {
    final result = await AnalysisGit.run(root, const [
      'rev-parse',
      '--verify',
      'HEAD',
    ]);
    if (result.exitCode == 0) revision = utf8.decode(result.stdout).trim();
  } on Exception {
    // Git이 없는 준비된 디렉터리도 분석 가능하다. 이력은 unknown으로 남긴다.
  }
  return {
    'origin': origin,
    'contentHash': capture.contentHash,
    'checkedContentHash': check.contentHash,
    'freshness': capture.contentHash == check.contentHash
        ? 'content-checked'
        : 'stale',
    'freshnessScope':
        'cache input enumeration; not external runtime state or immutable-cache package contents',
    'observedGitHead': revision,
    'revisionBinding':
        'context label only; content hashes identify inputs including working-tree edits',
    'projectInputFiles': capture.projectFiles.length,
  };
}

import 'dart:convert';
import 'dart:io';

import 'package:dartograph/src/cli/agent_setup.dart';
import 'package:dartograph/src/cli/dartograph_cli.dart';
import 'package:test/test.dart';

void main() {
  test('setup without --install prints the generated artifacts', () async {
    final output = StringBuffer();
    final error = StringBuffer();
    final status = await runDartograph(['setup'], output: output, error: error);

    expect(status, ExitStatus.success.code);
    expect(error.toString(), isEmpty);
    final printed = output.toString();
    expect(printed, contains('dartograph-impact.sh'));
    expect(printed, contains('"PostToolUse"'));
    expect(printed, contains('"mcpServers"'));
  });

  test('setup --install writes hook script and merges both configs', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-setup-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    final output = StringBuffer();
    final error = StringBuffer();
    final status = await runDartograph(
      ['setup', '--install', temporary.path],
      output: output,
      error: error,
    );

    expect(status, ExitStatus.success.code);
    final script = File('${temporary.path}/.claude/hooks/dartograph-impact.sh');
    expect(script.existsSync(), isTrue);
    expect(script.readAsStringSync(), contains('dartograph impact'));

    final settings =
        jsonDecode(
              File(
                '${temporary.path}/.claude/settings.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final postToolUse =
        (settings['hooks'] as Map<String, Object?>)['PostToolUse'] as List;
    expect(postToolUse, hasLength(1));
    expect(jsonEncode(postToolUse.first), contains('dartograph-impact.sh'));

    final mcp =
        jsonDecode(File('${temporary.path}/.mcp.json').readAsStringSync())
            as Map<String, Object?>;
    expect(
      (mcp['mcpServers'] as Map<String, Object?>)['dartograph'],
      <String, Object?>{
        'command': 'dartograph',
        'args': ['mcp'],
      },
    );
  });

  test('setup --install preserves existing settings and MCP entries', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-setup-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    Directory('${temporary.path}/.claude').createSync();
    File(
      '${temporary.path}/.claude/settings.json',
    ).writeAsStringSync('{"env": {"KEEP": "1"}, "hooks": {"PreToolUse": []}}');
    File(
      '${temporary.path}/.mcp.json',
    ).writeAsStringSync('{"mcpServers": {"other": {"command": "other-tool"}}}');

    final status = await runDartograph(
      ['setup', '--install', temporary.path],
      output: StringBuffer(),
      error: StringBuffer(),
    );
    expect(status, ExitStatus.success.code);

    final settings =
        jsonDecode(
              File(
                '${temporary.path}/.claude/settings.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect((settings['env'] as Map)['KEEP'], '1');
    final hooks = settings['hooks'] as Map<String, Object?>;
    expect(hooks['PreToolUse'], isEmpty);
    expect(hooks['PostToolUse'], hasLength(1));

    final mcp =
        jsonDecode(File('${temporary.path}/.mcp.json').readAsStringSync())
            as Map<String, Object?>;
    final servers = mcp['mcpServers'] as Map<String, Object?>;
    expect(servers.keys, unorderedEquals(['other', 'dartograph']));
  });

  test(
    'setup --install fails without --force when the script exists',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-setup-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final script = File(
        '${temporary.path}/.claude/hooks/dartograph-impact.sh',
      )..createSync(recursive: true);
      script.writeAsStringSync('custom hook');

      final error = StringBuffer();
      final status = await runDartograph([
        'setup',
        '--install',
        temporary.path,
      ], error: error);

      expect(status, ExitStatus.usage.code);
      expect(error.toString(), contains('Pass --force'));
      expect(script.readAsStringSync(), 'custom hook');
    },
  );

  test('setup --force replaces a symlink at the script path itself', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-setup-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    final outside = File('${temporary.path}/outside.sh')
      ..writeAsStringSync('precious');
    final link = Link('${temporary.path}/.claude/hooks/dartograph-impact.sh')
      ..createSync(outside.path, recursive: true);

    final status = await runDartograph(
      ['setup', '--install', temporary.path, '--force'],
      output: StringBuffer(),
      error: StringBuffer(),
    );

    expect(status, ExitStatus.success.code);
    expect(outside.readAsStringSync(), 'precious');
    expect(FileSystemEntity.isLinkSync(link.path), isFalse);
  });

  test(
    'setup --install keeps invalid existing settings.json untouched',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-setup-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      Directory('${temporary.path}/.claude').createSync();
      final settings = File('${temporary.path}/.claude/settings.json')
        ..writeAsStringSync('{not json');

      final error = StringBuffer();
      final status = await runDartograph([
        'setup',
        '--install',
        temporary.path,
      ], error: error);

      expect(status, ExitStatus.failure.code);
      expect(error.toString(), contains('Setup failed'));
      expect(settings.readAsStringSync(), '{not json');
    },
  );

  test(
    'setup --install keeps settings whose hooks are the wrong shape',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-setup-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      Directory('${temporary.path}/.claude').createSync();
      final settings = File('${temporary.path}/.claude/settings.json')
        ..writeAsStringSync('{"hooks": "oops"}');

      final status = await runDartograph([
        'setup',
        '--install',
        temporary.path,
      ], error: StringBuffer());

      expect(status, ExitStatus.failure.code);
      expect(settings.readAsStringSync(), '{"hooks": "oops"}');
    },
  );

  test('setup reports usage 64 for invalid arguments', () async {
    final error1 = StringBuffer();
    final status1 = await runDartograph([
      'setup',
      '--force',
      '--force',
    ], error: error1);
    expect(status1, ExitStatus.usage.code);

    final error2 = StringBuffer();
    final status2 = await runDartograph(['setup', '--install'], error: error2);
    expect(status2, ExitStatus.usage.code);

    final error3 = StringBuffer();
    final status3 = await runDartograph([
      'setup',
      '--install',
      '/nonexistent/dartograph-dir',
    ], error: error3);
    expect(status3, ExitStatus.usage.code);
    expect(error3.toString(), contains('not a directory'));
  });

  test('hook script skips out-of-project edits with a visible note', () async {
    if (Platform.isWindows) return; // 훅은 POSIX 셸 스크립트다.
    final temporary = await Directory.systemTemp.createTemp('dartograph-hook-');
    addTearDown(() => temporary.delete(recursive: true));
    final script = File('${temporary.path}/hook.sh')
      ..writeAsStringSync(agentHookScript);
    final project = Directory('${temporary.path}/proj')..createSync();

    final process = await Process.start(
      'sh',
      [script.path],
      environment: {'CLAUDE_PROJECT_DIR': project.path},
    );
    process.stdin.writeln('{"tool_input": {"file_path": "/elsewhere/x.dart"}}');
    await process.stdin.close();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    expect(await process.exitCode, 0);
    expect(stderr, contains('outside'));

    // CLAUDE_PROJECT_DIR 끝의 슬래시가 있어도 프로젝트 안 파일은 skip되지
    // 않는다 — PATH를 비워 dartograph 호출이 어디서도 실패하게 두고, 밖
    // 판정 문구가 안 나오는 것으로 안쪽 분기 진입을 확인한다.
    final inside = await Process.start(
      '/bin/sh',
      [script.path],
      environment: {
        'CLAUDE_PROJECT_DIR': '${project.path}/',
        // sed·mktemp은 쓸 수 있지만 dartograph은 못 찾는 PATH다.
        'PATH': '${temporary.path}/empty-bin:/usr/bin:/bin',
      },
    );
    inside.stdin.writeln(
      '{"tool_input": {"file_path": "${project.path}/lib/x.dart"}}',
    );
    await inside.stdin.close();
    final insideStderr = await inside.stderr.transform(utf8.decoder).join();
    // dartograph를 못 찾으면(exit 127) 게이트는 조용히 통과하지 않고
    // 실패를 보고한다.
    expect(await inside.exitCode, 2);
    expect(insideStderr, isNot(contains('outside')));
    expect(insideStderr, contains('could not run'));
  });

  test('hook fails closed when the tool input cannot be parsed', () async {
    if (Platform.isWindows) return; // 훅은 POSIX 셸 스크립트다.
    final temporary = await Directory.systemTemp.createTemp('dartograph-hook-');
    addTearDown(() => temporary.delete(recursive: true));
    final script = File('${temporary.path}/hook.sh')
      ..writeAsStringSync(agentHookScript);
    final project = Directory('${temporary.path}/proj')..createSync();

    Future<({int code, String err})> runHook(String line) async {
      final process = await Process.start(
        '/bin/sh',
        [script.path],
        environment: {
          'CLAUDE_PROJECT_DIR': project.path,
          'PATH': '${temporary.path}/empty-bin:/usr/bin:/bin',
        },
      );
      process.stdin.writeln(line);
      await process.stdin.close();
      final err = await process.stderr.transform(utf8.decoder).join();
      return (code: await process.exitCode, err: err);
    }

    // 깨진 JSON은 file_path를 해석할 수 없다 — 게이트를 통과시키지 않는다.
    final malformed = await runHook('{"tool_input": {"file_path": ');
    expect(malformed.code, 2);
    expect(malformed.err, contains('could not be parsed'));

    // 이스케이프된 따옴표가 들어간 경로는 파서가 정확히 해석한다 —
    // sed가 잘라낸 경로로 조용히 스킵되지 않는다.
    final escaped = await runHook(
      '{"tool_input": {"file_path": "${project.path}/lib/weird\\"q.dart"}}',
    );
    expect(escaped.code, 2); // dartograph 부재 → 실패 보고(게이트는 동작했다)
    expect(escaped.err, isNot(contains('skipped')));
  });

  test('mergeClaudeSettings treats null keys as empty', () {
    // 명시적으로 지운 "hooks": null이나 "PostToolUse": null은 거부하지 않는다.
    expect(mergeClaudeSettings('{"hooks": null}'), isNotNull);
    expect(mergeClaudeSettings('{"hooks": {"PostToolUse": null}}'), isNotNull);
  });

  test('mergeClaudeSettings is idempotent for an existing dartograph hook', () {
    final once = mergeClaudeSettings(null);
    expect(mergeClaudeSettings(once), isNull);
    // 다른 훅 항목이 있으면 목록에 추가한다.
    final withOther = mergeClaudeSettings(
      '{"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": []}]}}',
    );
    final postToolUse =
        ((jsonDecode(withOther!) as Map)['hooks'] as Map)['PostToolUse']
            as List;
    expect(postToolUse, hasLength(2));
  });

  test('mergeMcpConfig treats a null mcpServers key as empty', () {
    expect(mergeMcpConfig('{"mcpServers": null}', force: false), isNotNull);
  });

  test('mergeMcpConfig skips an existing dartograph entry without force', () {
    const existing = '{"mcpServers": {"dartograph": {"command": "old"}}}';
    expect(mergeMcpConfig(existing, force: false), isNull);
    final replaced = mergeMcpConfig(existing, force: true)!;
    final servers =
        (jsonDecode(replaced) as Map)['mcpServers'] as Map<String, Object?>;
    expect(servers['dartograph'], containsPair('command', 'dartograph'));
  });

  test('removeClaudeSettingsHook keeps unrelated hook entries', () {
    const existing =
        '{"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": []}, '
        '{"matcher": "Edit", "hooks": [{"type": "command", '
        '"command": "run dartograph-impact.sh"}]}]}}';
    final remaining = removeClaudeSettingsHook(existing)!;
    final postToolUse =
        ((jsonDecode(remaining) as Map)['hooks'] as Map)['PostToolUse'] as List;
    expect(postToolUse, hasLength(1));
    expect((postToolUse.single as Map)['matcher'], 'Bash');
  });

  test('removeMcpServerEntry keeps unrelated servers', () {
    const existing =
        '{"mcpServers": {"other": {"command": "x"}, '
        '"dartograph": {"command": "dartograph"}}}';
    final remaining = removeMcpServerEntry(existing)!;
    final servers =
        (jsonDecode(remaining) as Map)['mcpServers'] as Map<String, Object?>;
    expect(servers.keys, unorderedEquals(['other']));
  });

  test('removeOpenCodeEntry keeps unrelated mcp servers', () {
    const existing =
        '{"mcp": {"other": {"enabled": true}, '
        '"dartograph": {"enabled": true}}}';
    final remaining = removeOpenCodeEntry(existing)!;
    final mcp = (jsonDecode(remaining) as Map)['mcp'] as Map<String, Object?>;
    expect(mcp.keys, unorderedEquals(['other']));
  });

  test('setup --target cursor prints the Cursor MCP document', () async {
    final output = StringBuffer();
    final error = StringBuffer();
    final status = await runDartograph(
      ['setup', '--target', 'cursor'],
      output: output,
      error: error,
    );
    expect(status, ExitStatus.success.code);
    expect(error.toString(), isEmpty);
    expect(output.toString(), contains('.cursor/mcp.json'));
    expect(output.toString(), contains('"mcpServers"'));
  });

  test(
    'setup --target cursor installs and uninstalls .cursor/mcp.json',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-setup-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final config = File('${temporary.path}/.cursor/mcp.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"mcpServers": {"other": {"command": "other-tool"}}}',
        );

      final installStatus = await runDartograph(
        ['setup', '--target', 'cursor', '--install', temporary.path],
        output: StringBuffer(),
        error: StringBuffer(),
      );
      expect(installStatus, ExitStatus.success.code);
      final servers =
          (jsonDecode(config.readAsStringSync()) as Map)['mcpServers']
              as Map<String, Object?>;
      expect(servers.keys, unorderedEquals(['other', 'dartograph']));
      // 같은 항목이 이미 있으면 건너뛴다.
      expect(
        await runDartograph([
          'setup',
          '--target',
          'cursor',
          '--install',
          temporary.path,
        ]),
        ExitStatus.success.code,
      );
      expect(servers, hasLength(2));

      final uninstallStatus = await runDartograph(
        ['setup', '--target', 'cursor', '--uninstall', temporary.path],
        output: StringBuffer(),
        error: StringBuffer(),
      );
      expect(uninstallStatus, ExitStatus.success.code);
      final remaining =
          (jsonDecode(config.readAsStringSync()) as Map)['mcpServers']
              as Map<String, Object?>;
      expect(remaining.keys, unorderedEquals(['other']));
    },
  );

  test(
    'setup --target opencode preserves other keys and uninstalls its entry',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-setup-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final config = File('${temporary.path}/opencode.json')
        ..writeAsStringSync('{"theme": "dark"}');

      final installStatus = await runDartograph(
        ['setup', '--target', 'opencode', '--install', temporary.path],
        output: StringBuffer(),
        error: StringBuffer(),
      );
      expect(installStatus, ExitStatus.success.code);
      final decoded =
          jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
      expect(decoded['theme'], 'dark');
      expect((decoded['mcp'] as Map)['dartograph'], <String, Object?>{
        'type': 'local',
        'command': <String>['dartograph', 'mcp'],
        'enabled': true,
      });

      final uninstallStatus = await runDartograph(
        ['setup', '--target', 'opencode', '--uninstall', temporary.path],
        output: StringBuffer(),
        error: StringBuffer(),
      );
      expect(uninstallStatus, ExitStatus.success.code);
      final after =
          jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
      expect(after['theme'], 'dark');
      expect(after.containsKey('mcp'), isFalse);
    },
  );

  test(
    'setup --uninstall for Claude removes hook, MCP entry, and script',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-setup-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final installStatus = await runDartograph(
        ['setup', '--install', temporary.path],
        output: StringBuffer(),
        error: StringBuffer(),
      );
      expect(installStatus, ExitStatus.success.code);
      final script = File(
        '${temporary.path}/.claude/hooks/dartograph-impact.sh',
      );
      expect(script.existsSync(), isTrue);

      final uninstallStatus = await runDartograph(
        ['setup', '--uninstall', temporary.path],
        output: StringBuffer(),
        error: StringBuffer(),
      );
      expect(uninstallStatus, ExitStatus.success.code);
      expect(script.existsSync(), isFalse);
      final mcp =
          jsonDecode(File('${temporary.path}/.mcp.json').readAsStringSync())
              as Map<String, Object?>;
      // mcpServers의 유일한 항목이었으므로 컨테이너도 함께 사라진다.
      expect(mcp['mcpServers'], isNull);
      final settings =
          jsonDecode(
                File(
                  '${temporary.path}/.claude/settings.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final hooks = settings['hooks'];
      expect(
        hooks == null || (hooks as Map<String, Object?>)['PostToolUse'] == null,
        isTrue,
      );
      // 블록만 담긴 CLAUDE.md는 설치가 만든 것이므로 함께 사라진다.
      expect(File('${temporary.path}/CLAUDE.md').existsSync(), isFalse);
    },
  );

  test('setup --install adds the managed block to CLAUDE.md', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-setup-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    final status = await runDartograph(
      ['setup', '--install', temporary.path],
      output: StringBuffer(),
      error: StringBuffer(),
    );
    expect(status, ExitStatus.success.code);

    final guide = File('${temporary.path}/CLAUDE.md');
    expect(guide.existsSync(), isTrue);
    final text = guide.readAsStringSync();
    expect(text, contains(agentGuideBeginMarker));
    expect(text, contains('dartograph dead'));
    expect(text, contains('dartograph query'));
    expect(text, contains(agentGuideEndMarker));
  });

  test('setup --install merges the block into an existing CLAUDE.md', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-setup-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    File(
      '${temporary.path}/CLAUDE.md',
    ).writeAsStringSync('# Project rules\n\nKeep user content.\n');

    final status = await runDartograph(
      ['setup', '--install', temporary.path],
      output: StringBuffer(),
      error: StringBuffer(),
    );
    expect(status, ExitStatus.success.code);

    final text = File('${temporary.path}/CLAUDE.md').readAsStringSync();
    expect(text, contains('Keep user content.'));
    expect(text, contains(agentGuideBeginMarker));
  });

  test('setup --install prefers AGENTS.md when only it exists', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-setup-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    File('${temporary.path}/AGENTS.md').writeAsStringSync('# Agent guide\n');

    final status = await runDartograph(
      ['setup', '--install', temporary.path],
      output: StringBuffer(),
      error: StringBuffer(),
    );
    expect(status, ExitStatus.success.code);

    expect(File('${temporary.path}/CLAUDE.md').existsSync(), isFalse);
    expect(
      File('${temporary.path}/AGENTS.md').readAsStringSync(),
      contains(agentGuideBeginMarker),
    );
  });

  test('setup --install --force keeps a single guide block', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'dartograph-setup-',
    );
    addTearDown(() => temporary.delete(recursive: true));

    // 재설치는 훅 스크립트 가드 때문에 --force가 필요하다 — 그 경로에서도
    // 블록이 중복되지 않아야 한다.
    for (final extra in const <List<String>>[
      <String>[],
      <String>['--force'],
    ]) {
      final status = await runDartograph(
        ['setup', '--install', temporary.path, ...extra],
        output: StringBuffer(),
        error: StringBuffer(),
      );
      expect(status, ExitStatus.success.code);
    }
    final text = File('${temporary.path}/CLAUDE.md').readAsStringSync();
    expect(agentGuideBeginMarker.allMatches(text), hasLength(1));
  });

  test(
    'setup --uninstall strips the block but keeps other guide content',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dartograph-setup-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      File(
        '${temporary.path}/CLAUDE.md',
      ).writeAsStringSync('# Project rules\n\nKeep user content.\n');

      expect(
        await runDartograph(
          ['setup', '--install', temporary.path],
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.success.code,
      );
      expect(
        await runDartograph(
          ['setup', '--uninstall', temporary.path],
          output: StringBuffer(),
          error: StringBuffer(),
        ),
        ExitStatus.success.code,
      );

      final guide = File('${temporary.path}/CLAUDE.md');
      expect(guide.existsSync(), isTrue);
      final text = guide.readAsStringSync();
      expect(text, contains('Keep user content.'));
      expect(text, isNot(contains(agentGuideBeginMarker)));
    },
  );

  test('mergeClaudeGuide appends to content and skips an existing block', () {
    final merged = mergeClaudeGuide('# Rules\n', force: false)!;
    expect(merged, startsWith('# Rules\n\n'));
    expect(merged, contains(agentGuideBeginMarker));
    // 이미 블록이 있으면 force 없이는 건드리지 않는다.
    expect(mergeClaudeGuide(merged, force: false), isNull);
  });

  test('mergeClaudeGuide --force replaces a stale block in place', () {
    final stale =
        'head\n$agentGuideBeginMarker\noutdated\n$agentGuideEndMarker\ntail\n';
    final merged = mergeClaudeGuide(stale, force: true)!;
    expect(merged, startsWith('head\n'));
    expect(merged, contains('## dartograph'));
    expect(merged, isNot(contains('outdated')));
    expect(merged, endsWith('tail\n'));
  });

  test('mergeClaudeGuide fails closed on malformed markers', () {
    expect(
      () => mergeClaudeGuide(agentGuideBeginMarker, force: false),
      throwsFormatException,
    );
    expect(
      () => mergeClaudeGuide(agentGuideEndMarker, force: false),
      throwsFormatException,
    );
    expect(
      () => mergeClaudeGuide(
        '$agentGuideBeginMarker x $agentGuideBeginMarker $agentGuideEndMarker',
        force: false,
      ),
      throwsFormatException,
    );
    expect(
      () => mergeClaudeGuide(
        '$agentGuideEndMarker x $agentGuideBeginMarker',
        force: false,
      ),
      throwsFormatException,
    );
  });

  test('removeClaudeGuide strips only the managed block', () {
    final text =
        'alpha\n\n$agentGuideBeginMarker\nbody\n$agentGuideEndMarker\n\nomega\n';
    expect(removeClaudeGuide(text), 'alpha\n\nomega\n');
    // 블록이 없으면 null — 호출자가 파일을 그대로 둔다.
    expect(removeClaudeGuide('alpha\n'), isNull);
    expect(removeClaudeGuide(null), isNull);
  });

  test(
    'setup rejects unknown targets and unsupported argument shapes',
    () async {
      expect(
        await runDartograph([
          'setup',
          '--target',
          'vscode',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      expect(
        await runDartograph([
          'setup',
          '--install',
          '.',
          '--uninstall',
          '.',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      // claude는 프로젝트 루트가 필요하다.
      expect(
        await runDartograph(['setup', '--install'], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      expect(
        await runDartograph(['setup', '--target'], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      // --target 중복은 다른 플래그와 같이 usage다 — 마지막 값을 쓰지 않는다.
      expect(
        await runDartograph([
          'setup',
          '--target',
          'cursor',
          '--target',
          'opencode',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
      // codex는 전역 설정만 다룬다 — 루트 인자를 조용히 무시하지 않는다.
      expect(
        await runDartograph([
          'setup',
          '--target',
          'codex',
          '--install',
          '.',
        ], error: StringBuffer()),
        ExitStatus.usage.code,
      );
    },
  );

  test('mergeCodexConfig and removeCodexConfig preserve other tables', () {
    const existing = 'model = "o3"\n\n[foo]\nbar = 1\n';
    final merged = mergeCodexConfig(existing, force: false)!;
    expect(merged, contains('model = "o3"'));
    expect(merged, contains('[foo]'));
    expect(merged, contains('[mcp_servers.dartograph]'));
    expect(mergeCodexConfig(merged, force: false), isNull);
    final replaced = mergeCodexConfig(merged, force: true)!;
    expect(
      RegExp(r'\[mcp_servers\.dartograph\]').allMatches(replaced).length,
      1,
    );
    final removed = removeCodexConfig(replaced)!;
    expect(removed, isNot(contains('mcp_servers.dartograph')));
    expect(removed, contains('[foo]'));
    expect(removed, contains('bar = 1'));
    expect(removeCodexConfig('model = "o3"\n'), isNull);
  });

  test('mergeCodexConfig fails closed on foreign dartograph shapes', () {
    // 점 키·배열 표·인라인 표·[mcp_servers] 하위 키로 적힌 dartograph, 또는
    // 표가 아닌 값으로 정의된 mcp_servers 위에 표를 덧붙이면 같은 표의
    // 중복 정의로 config.toml 전체가 파싱 에러가 된다 — 실패로 돌린다.
    for (final existing in [
      'mcp_servers.dartograph.command = "dartograph"\n',
      'mcp_servers.dartograph = { command = "dartograph" }\n',
      'mcp_servers.dartograph = "x"\n',
      '[[mcp_servers.dartograph]]\ncommand = "dartograph"\n',
      // `mcp_servers`의 값 정의는 인라인 표·배열·스칼라 모두 표 헤더로
      // 확장할 수 없다 — dartograph 유무와 무관하게 덧붙이면 깨진다.
      'mcp_servers = { dartograph = { command = "dartograph" } }\n',
      'mcp_servers = { a = 1, dartograph = { x = 1 } }\n',
      'mcp_servers = { linear = { x = 1 } } # TODO: dartograph 검토\n',
      'mcp_servers = { note = "dartograph" }\n',
      'mcp_servers = { xdartograph = 1 }\n',
      'mcp_servers = { note = "dartograph = 1" }\n',
      'mcp_servers = [{ command = "dartograph" }]\n',
      'mcp_servers = "x"\n',
      '[mcp_servers."dartograph"]\ncommand = "dartograph"\n',
      '["mcp_servers".dartograph]\ncommand = "dartograph"\n',
      '"mcp_servers".dartograph.command = "dartograph"\n',
      '[mcp_servers]\ndartograph = { command = "dartograph" }\n',
      '[mcp_servers]\ndartograph.command = "dartograph"\n',
      // 배열 안의 [ 행은 표 경계를 리셋하지 않는다 — 하위 키는 여전히 잡힌다.
      '[mcp_servers]\nflags = [\n  [1]\n]\ndartograph = { command = "d" }\n',
      '[mcp_servers.dartograph.sub]\nkey = 1\n',
    ]) {
      expect(
        () => mergeCodexConfig(existing, force: true),
        throwsFormatException,
        reason: existing,
      );
    }
    // 다른 서버의 정의·접두어·접미 이름·다른 표 안의 점 키·주석·문자열 값의
    // dartograph 언급은 충돌이 아니다 — 표는 정상 병합된다.
    for (final existing in [
      'mcp_servers.linear.command = "x"\n',
      'mcp_servers.dartograph_cli.command = "x"\n',
      'mcp_servers.dartograph_cli = "x"\n',
      '[mcp_servers.dartograph_legacy]\ncommand = "x"\n',
      '[legacy]\nmcp_servers.dartograph.command = "old"\n',
      // 이스케이프된 따옴표 안의 ]는 배열 깊이를 흔들지 않는다.
      'args = ["--filter=\\"a]b\\""]\n',
    ]) {
      expect(
        mergeCodexConfig(existing, force: false),
        contains('[mcp_servers.dartograph]'),
        reason: existing,
      );
    }
    // 표 헤더의 끝 주석·공백 변형도 표준 정의다 — 건너뛰고 되돌릴 수 있다.
    const commented = '[mcp_servers.dartograph] # note\ncommand = "x"\n';
    expect(mergeCodexConfig(commented, force: false), isNull);
    expect(removeCodexConfig(commented), isNot(contains('command')));
    const spaced = '[ mcp_servers . dartograph ]\ncommand = "x"\n';
    expect(mergeCodexConfig(spaced, force: false), isNull);
    expect(removeCodexConfig(spaced), isNot(contains('command')));
    // 이스케이프된 따옴표가 있는 배열 뒤에 오는 표 헤더도 여전히 찾는다.
    final escaped = 'args = ["--filter=\\"a]b\\""]\n$codexMcpTomlBlock';
    expect(mergeCodexConfig(escaped, force: false), isNull);
  });

  test('codex strip keeps array brackets inside other tables', () {
    // 다른 표의 여러 줄 배열 안 [ 행은 표 경계가 아니다 — 값으로 보존한다.
    const existing =
        '[other]\narr = [\n  [1]\n]\n\n[mcp_servers.dartograph]\ncommand = "x"\n';
    final removed = removeCodexConfig(existing)!;
    expect(removed, contains('[1]'));
    expect(removed, isNot(contains('mcp_servers.dartograph')));
    // 지우는 블록 안의 배열·문자열도 끝을 잘못 읽지 않는다.
    const nested =
        '[mcp_servers.dartograph]\narr = [\n  [1]\n]\nx = """\n[a]\n"""\n'
        '[foo]\nbar = 1\n';
    expect(removeCodexConfig(nested), '[foo]\nbar = 1\n');
    // 지우는 블록 뒤 표의 이스케이프된 따옴표가 깊이를 어긋내게 해
    // 이후 표까지 삼키지 않는다.
    const escaped =
        '[mcp_servers.dartograph]\ncommand = "x"\n'
        '[mcp_servers]\nargs = ["--filter=\\"a]b\\""]\n[foo]\nbar = 1\n';
    final stripped = removeCodexConfig(escaped)!;
    expect(stripped, contains('[mcp_servers]'));
    expect(stripped, contains('args = ["--filter=\\"a]b\\""]'));
    expect(stripped, contains('[foo]'));
    expect(stripped, isNot(contains('mcp_servers.dartograph')));
  });

  test('codex merge keeps table-like lines inside multiline strings', () {
    // 다른 표의 문자열 안 `[mcp_servers.dartograph]`는 헤더가 아니라 값이다 —
    // 항목이 있는 것으로 오인해 건너뛰거나 지우면 안 된다.
    const existing =
        '[other]\ndoc = """\n[mcp_servers.dartograph]\nnot a table\n"""\n';
    final merged = mergeCodexConfig(existing, force: false)!;
    expect(merged, contains('not a table'));
    expect(RegExp(r'\[mcp_servers\.dartograph\]').allMatches(merged).length, 2);
  });

  test('mergeOpenCodeConfig preserves other keys and is idempotent', () {
    final merged = mergeOpenCodeConfig('{"theme": "dark"}', force: false)!;
    final decoded = jsonDecode(merged) as Map<String, Object?>;
    expect(decoded['theme'], 'dark');
    expect((decoded['mcp'] as Map)['dartograph'], <String, Object?>{
      'type': 'local',
      'command': <String>['dartograph', 'mcp'],
      'enabled': true,
    });
    expect(mergeOpenCodeConfig(merged, force: false), isNull);
    expect(removeOpenCodeEntry(merged), contains('"theme"'));
    expect(removeOpenCodeEntry('{"theme": "dark"}'), isNull);
  });
}

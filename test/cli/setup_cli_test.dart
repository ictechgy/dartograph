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

  test('mergeMcpConfig skips an existing dartograph entry without force', () {
    const existing = '{"mcpServers": {"dartograph": {"command": "old"}}}';
    expect(mergeMcpConfig(existing, force: false), isNull);
    final replaced = mergeMcpConfig(existing, force: true)!;
    final servers =
        (jsonDecode(replaced) as Map)['mcpServers'] as Map<String, Object?>;
    expect(servers['dartograph'], containsPair('command', 'dartograph'));
  });
}

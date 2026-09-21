import 'package:test/test.dart';

import '../../tool/agent_benchmark/usage_detection.dart';

void main() {
  group('invokesDartograph', () {
    test('does not count grep paths or text mentions', () {
      expect(
        invokesDartograph(
          'grep -R dartograph /private/tmp/dartograph-benchmark.0gQO6G',
        ),
        isFalse,
      );
      expect(
        invokesDartograph(
          'grep -n "dartograph" /private/tmp/dartograph-benchmark.0gQO6G/results',
        ),
        isFalse,
      );
      expect(invokesDartograph('echo "dartograph query"'), isFalse);
      expect(invokesDartograph("echo 'dartograph'"), isFalse);
    });

    test('detects direct and quoted executable forms', () {
      expect(invokesDartograph('dartograph query lib'), isTrue);
      expect(invokesDartograph('"/opt/bin/dartograph" query lib'), isTrue);
      expect(invokesDartograph('FOO=bar exec time dartograph query'), isTrue);
      expect(invokesDartograph('printf ok; dartograph query'), isTrue);
      expect(
        invokesDartograph('printf ok | /opt/bin/dartograph query'),
        isTrue,
      );
    });

    test('detects Dart package runner variants', () {
      expect(invokesDartograph('dart run dartograph query'), isTrue);
      expect(invokesDartograph('dart run dartograph:dartograph query'), isTrue);
      expect(invokesDartograph('dart pub global run dartograph query'), isTrue);
      expect(
        invokesDartograph('dart pub global run dartograph:dartograph'),
        isTrue,
      );
      expect(
        invokesDartograph(
          'env DART_VM_OPTIONS=x dart pub global run dartograph',
        ),
        isTrue,
      );
      expect(invokesDartograph('timeout 30 dartograph query'), isTrue);
      expect(invokesDartograph('timeout -k 5 30 dartograph query'), isTrue);
      expect(
        invokesDartograph('timeout --signal TERM 30 dartograph query'),
        isTrue,
      );
      expect(invokesDartograph('nice -n 10 dartograph query'), isTrue);
      expect(invokesDartograph('sudo -u ci dartograph query'), isTrue);
      expect(invokesDartograph('exec -a name dartograph query'), isTrue);
      expect(invokesDartograph('env -u PATH dartograph query'), isTrue);
      expect(
        invokesDartograph('env --file env.file dartograph query'),
        isFalse,
      );
    });

    test('does not count lookup wrappers', () {
      expect(invokesDartograph('command -v dartograph'), isFalse);
      expect(invokesDartograph('command -V dartograph'), isFalse);
      expect(invokesDartograph('which dartograph'), isFalse);
      expect(invokesDartograph('type dartograph'), isFalse);
      expect(invokesDartograph('env command -v dartograph'), isFalse);
    });

    test('handles substitutions and nested command boundaries', () {
      expect(invokesDartograph('echo "\$(dartograph query)"'), isTrue);
      expect(invokesDartograph("echo \"'\$(dartograph query)'\""), isTrue);
      expect(invokesDartograph('echo `dartograph query`'), isTrue);
      expect(invokesDartograph('echo "`dartograph query`"'), isTrue);
      expect(invokesDartograph('echo "\$(grep dartograph file)"'), isFalse);
      expect(invokesDartograph("echo '\$(dartograph query)'"), isFalse);
      expect(invokesDartograph('# comment; dartograph query'), isFalse);
      expect(invokesDartograph('# \$(dartograph query)'), isFalse);
      expect(invokesDartograph('echo \$('), isFalse);
      expect(invokesDartograph('echo `'), isFalse);
      expect(invokesDartograph("echo `grep dartograph \\"), isFalse);
      expect(invokesDartograph('da\\\nrtograph query'), isTrue);
      expect(invokesDartograph('printf x && echo y\ndartograph query'), isTrue);
    });

    test('handles Dart source entrypoints', () {
      expect(invokesDartograph('dart run bin/dartograph.dart query'), isTrue);
      expect(invokesDartograph('dart ./bin/dartograph.dart query'), isTrue);
      expect(
        invokesDartograph('dart run /workspace/bin/dartograph.dart query'),
        isTrue,
      );
    });

    test('masks heredoc literals but checks unquoted substitutions', () {
      expect(invokesDartograph('cat <<\\'), isFalse);
      expect(invokesDartograph("cat <<'EOF'\ndartograph query\nEOF"), isFalse);
      expect(invokesDartograph('# <<EOF\ndartograph query\nEOF'), isTrue);
      expect(invokesDartograph('cat <<< "text"\ndartograph query'), isTrue);
      expect(invokesDartograph('cat <<EOF\ndartograph query\nEOF'), isFalse);
      expect(invokesDartograph('cat <<EOF\n\$(dartograph query)\nEOF'), isTrue);
      expect(
        invokesDartograph("cat <<'EOF'\n\$(dartograph query)\nEOF"),
        isFalse,
      );
      expect(
        invokesDartograph("cat <<EOF\n'\$(dartograph query)'\nEOF"),
        isTrue,
      );
      expect(
        invokesDartograph('cat <<EOF; echo ok\ntext\nEOF\ndartograph query'),
        isTrue,
      );
      expect(
        invokesDartograph(
          'cat <<A <<B\ntext A\nA\ntext B\nB\ndartograph query',
        ),
        isTrue,
      );
      expect(invokesDartograph('cat <<\\EOF\ndartograph query\nEOF'), isFalse);
      expect(
        invokesDartograph('cat <<\\EOF\ntext\nEOF\ndartograph query'),
        isTrue,
      );
      expect(
        invokesDartograph(
          "cat <<'EOF'\ndartograph query\nEOF\ndartograph query",
        ),
        isTrue,
      );
    });
  });
}

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
      expect(invokesDartograph('nice -n 10 dartograph query'), isTrue);
      expect(invokesDartograph('env -u PATH dartograph query'), isTrue);
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
      expect(invokesDartograph('printf x && echo y\ndartograph query'), isTrue);
    });
  });
}

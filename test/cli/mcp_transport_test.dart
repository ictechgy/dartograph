import 'dart:async';
import 'dart:convert';

import 'package:dartograph/src/cli/mcp_server.dart';
import 'package:test/test.dart';

void main() {
  const ping = '{"jsonrpc":"2.0","id":2,"method":"ping"}';

  Future<List<String>> lines(List<List<int>> chunks, {int maxBytes = 128}) =>
      Stream.fromIterable(
        chunks,
      ).transform(boundedUtf8Lines(maxBytes)).toList();

  Future<List<Map<String, Object?>>> exchange(List<List<int>> chunks) async {
    final output = StringBuffer();
    final status = await runMcpServer(
      input: Stream.fromIterable(chunks).transform(boundedUtf8Lines(128)),
      output: output,
      error: StringBuffer(),
      createCacheDirectory: () async => throw StateError('must stay lazy'),
      environment: const {},
    );
    expect(status, 0);
    return const LineSplitter()
        .convert(output.toString())
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
  }

  test(
    'an oversized valid JSON prefix never executes and the next line works',
    () async {
      final prefix = utf8.encode(ping.padRight(128));
      for (final chunks in [
        [
          <int>[...prefix, 0x20, 0x0a, ...utf8.encode('$ping\n')],
        ],
        [
          prefix,
          [0x20],
          utf8.encode('\n$ping\n'),
        ],
      ]) {
        final responses = await exchange(chunks);
        expect(responses, hasLength(2));
        expect(responses.first['id'], isNull);
        expect((responses.first['error'] as Map)['code'], -32700);
        expect(responses.last['id'], 2);
        expect(responses.last['result'], isEmpty);
      }
    },
  );

  test(
    'oversized whitespace and an unterminated valid prefix are rejected',
    () async {
      for (final bytes in [
        utf8.encode(' ' * 129),
        utf8.encode(ping.padRight(129)),
      ]) {
        final responses = await exchange([bytes]);
        expect(responses, hasLength(1));
        expect((responses.single['error'] as Map)['code'], -32700);
      }
    },
  );

  test(
    'malformed UTF-8 rejects the whole request without repairing its ID',
    () async {
      final responses = await exchange([
        utf8.encode('{"jsonrpc":"2.0","id":"'),
        [0xff],
        utf8.encode('","method":"ping"}\n$ping\n'),
      ]);
      expect(responses, hasLength(2));
      expect(responses.first['id'], isNull);
      expect((responses.first['error'] as Map)['code'], -32700);
      expect(responses.last['id'], 2);
      expect(responses.last['result'], isEmpty);
    },
  );

  test('UTF-8 is decoded after chunk assembly and measured in bytes', () async {
    const message = '{"name":"한😀�"}';
    final bytes = utf8.encode(message);
    expect(
      await lines([
        for (final byte in bytes) [byte],
      ], maxBytes: bytes.length),
      [message],
    );
    final rejected = await lines([bytes], maxBytes: bytes.length - 1);
    expect(rejected, hasLength(1));
    expect(() => jsonDecode(rejected.single), throwsFormatException);
  });

  test(
    'every split of an oversized line gives one error and recovers',
    () async {
      final bytes = utf8.encode('${ping.padRight(129)}\n$ping\n');
      for (var split = 0; split <= bytes.length; split++) {
        final framed = await lines([
          bytes.sublist(0, split),
          bytes.sublist(split),
        ]);
        expect(framed, hasLength(2), reason: 'split $split');
        expect(
          () => jsonDecode(framed.first),
          throwsFormatException,
          reason: 'split $split',
        );
        expect(framed.last, ping, reason: 'split $split');
      }
    },
  );

  test(
    'empty chunks, blank lines, CRLF and a final exact-limit line work',
    () async {
      final exact = ping.padRight(128);
      expect(
        await lines([
          [],
          utf8.encode('\n$ping\r'),
          utf8.encode('\n\n'),
          [],
          utf8.encode(exact),
        ]),
        ['$ping\r', exact],
      );
      expect(await lines([[], []]), isEmpty);
    },
  );

  test('one transformer keeps concurrently bound streams isolated', () async {
    final transformer = boundedUtf8Lines(128);
    final first = StreamController<List<int>>(sync: true);
    final second = StreamController<List<int>>(sync: true);
    final firstLines = first.stream.transform(transformer).toList();
    final secondLines = second.stream.transform(transformer).toList();
    first.add(utf8.encode('{"first":'));
    second.add(utf8.encode('{"second":2}\n'));
    await second.close();
    first.add(utf8.encode('1}\n'));
    await first.close();
    expect(await firstLines, ['{"first":1}']);
    expect(await secondLines, ['{"second":2}']);
  });

  test('one transformed broadcast stream isolates every listener', () async {
    final source = StreamController<List<int>>.broadcast(sync: true);
    final transformed = source.stream.transform(boundedUtf8Lines(128));
    final first = transformed.toList();
    final second = transformed.toList();
    source.add(utf8.encode('{"value":'));
    source.add(utf8.encode('1}\n'));
    await source.close();
    expect(await first, ['{"value":1}']);
    expect(await second, ['{"value":1}']);
  });

  test('invalid UTF-8 sequences cannot become valid string data', () async {
    for (final invalid in [
      [0x80],
      [0xc0, 0x80],
      [0xed, 0xa0, 0x80],
      [0xf4, 0x90, 0x80, 0x80],
      [0xe2, 0x82],
    ]) {
      final framed = await lines([
        utf8.encode('{"value":"'),
        invalid,
        utf8.encode('"}\n$ping\n'),
      ]);
      expect(framed, hasLength(2));
      expect(() => jsonDecode(framed.first), throwsFormatException);
      expect(framed.last, ping);
    }
    final incomplete = await lines([
      [0xe2, 0x82],
    ]);
    expect(() => jsonDecode(incomplete.single), throwsFormatException);
  });

  test(
    'source errors and stack traces are forwarded without losing bytes',
    () async {
      final source = StreamController<List<int>>(sync: true);
      final received = <String>[];
      final errors = <Object>[];
      final traces = <StackTrace>[];
      final done = Completer<void>();
      final error = StateError('source error');
      final trace = StackTrace.current;
      source.stream
          .transform(boundedUtf8Lines(128))
          .listen(
            received.add,
            onError: (Object error, StackTrace trace) {
              errors.add(error);
              traces.add(trace);
            },
            onDone: done.complete,
          );
      source.add(utf8.encode('{"value":'));
      source.addError(error, trace);
      source.add(utf8.encode('1}\n'));
      await source.close();
      await done.future;
      expect(received, ['{"value":1}']);
      expect(errors, [same(error)]);
      expect(traces, [same(trace)]);
    },
  );

  test('nonpositive byte limits fail immediately', () {
    expect(() => boundedUtf8Lines(0), throwsRangeError);
    expect(() => boundedUtf8Lines(-1), throwsRangeError);
  });
}

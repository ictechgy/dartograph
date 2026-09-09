import 'dart:io';
import 'package:dartograph/src/index/bridge_index.dart';
import 'package:test/test.dart';

void main() {
  // method-invoke 사실을 출력(결정적 정렬) 순서로 `method@channel` 추출한다.
  List<String> invokes(BridgeIndexResult result) => result.facts
      .where((fact) => fact['kind'] == 'method-invoke')
      .map((fact) => '${fact['method']}@${fact['channel']}')
      .toList();

  // channel-create 사실의 채널 이름을 출력 순서로 추출한다.
  List<String> created(BridgeIndexResult result) => result.facts
      .where((fact) => fact['kind'] == 'channel-create')
      .map((fact) => fact['channel']! as String)
      .toList();

  Future<Directory> writeFixture(String prefix, String source) async {
    final root = await Directory.systemTemp.createTemp(prefix);
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/channel.dart').writeAsString(source);
    return root;
  }

  group('bridge scope constructs', () {
    test('a channel resolves through a catch clause scope', () async {
      final root = await writeFixture('bridge-catch.', '''
import 'package:flutter/services.dart';
final outer = MethodChannel('outerChan');
void go() {
  try {
    outer.invokeMethod('inTry');
  } on Object catch (e, st) {
    outer.invokeMethod('inCatch');
    final scoped = MethodChannel('catchChan');
    scoped.invokeMethod('fromCatch');
  }
}
''');

      final result = indexBridges(root.path);

      // catch가 예외·스택트레이스 파라미터 스코프를 밀어도 바깥 채널이 해결되고,
      // catch 본문의 지역 채널은 그 스코프에 묶인다.
      expect(created(result), ['outerChan', 'catchChan']);
      expect(invokes(result), [
        'inTry@outerChan',
        'inCatch@outerChan',
        'fromCatch@catchChan',
      ]);
    });

    test('a channel resolves through a for-each loop scope', () async {
      final root = await writeFixture('bridge-for.', '''
import 'package:flutter/services.dart';
final outer = MethodChannel('loopOuter');
void go() {
  final items = [1, 2];
  for (final item in items) {
    outer.invokeMethod('inLoop');
    final scoped = MethodChannel('loopChan');
    scoped.invokeMethod('fromLoop');
  }
}
''');

      final result = indexBridges(root.path);

      // for-each 루프 변수 스코프를 밀어도 바깥 채널이 해결되고 지역 채널이 묶인다.
      expect(created(result), ['loopOuter', 'loopChan']);
      expect(invokes(result), ['inLoop@loopOuter', 'fromLoop@loopChan']);
    });

    test(
      'an enclosing block channel resolves inside a local function',
      () async {
        final root = await writeFixture('bridge-local-fn.', '''
import 'package:flutter/services.dart';
void go() {
  final c = MethodChannel('localFnChan');
  void helper() {
    c.invokeMethod('fromLocalFn');
  }
  helper();
}
''');

        final result = indexBridges(root.path);

        // 지역 함수 선언이 블록 스코프에 등록되고 본문에서 바깥 블록의 채널이 해결된다.
        expect(created(result), ['localFnChan']);
        expect(invokes(result), ['fromLocalFn@localFnChan']);
      },
    );

    test('a channel resolves inside a closure body', () async {
      final root = await writeFixture('bridge-closure.', '''
import 'package:flutter/services.dart';
void go() {
  final c = MethodChannel('closureChan');
  final invoke = () => c.invokeMethod('fromClosure');
  invoke();
}
''');

      final result = indexBridges(root.path);

      // 클로저(함수 표현식) 파라미터 스코프를 밀어도 포획된 채널이 해결된다.
      expect(created(result), ['closureChan']);
      expect(invokes(result), ['fromClosure@closureChan']);
    });

    test(
      'reassigning a channel variable rebinds it and unassigning drops it',
      () async {
        final root = await writeFixture('bridge-reassign.', '''
import 'package:flutter/services.dart';
void reassign() {
  var c = MethodChannel('firstChan');
  c.invokeMethod('m1');
  c = MethodChannel('secondChan');
  c.invokeMethod('m2');
}
void unassign() {
  var d = MethodChannel('dChan');
  d = null;
  d.invokeMethod('m3');
}
''');

        final result = indexBridges(root.path);

        expect(created(result), ['firstChan', 'secondChan', 'dChan']);
        // m1은 재대입 전 바인딩, m2는 재대입 후 바인딩을 쓴다. m3은 `d = null`로
        // 바인딩이 해제되어 method-invoke 사실을 내지 않고 미해결로 강등된다.
        // 방문자는 단일 패스(AST 소스 순서)라 재대입 바인딩은 그 지점 이후 호출에만
        // 반영된다(조건부 분기 재대입은 추적하지 않는 의도적 선택 — 이 테스트로 고정).
        // `d = null`은 실제 MethodChannel 타입엔 부적합하지만 스캐너는 parse만 보므로
        // (throwIfDiagnostics: false) unbind 분기를 행사하는 의도적 fixture다.
        expect(invokes(result), ['m1@firstChan', 'm2@secondChan']);
        expect(
          result.limitations.any(
            (s) => s.startsWith('unresolved-receiver-invocations:'),
          ),
          isTrue,
        );
      },
    );
  });

  group('scope declarations shadow outer channels', () {
    test(
      'a catch parameter shadows an outer channel of the same name',
      () async {
        final root = await writeFixture('bridge-catch-shadow.', '''
import 'package:flutter/services.dart';
final outer = MethodChannel('outerChan');
void go() {
  try {
    outer.invokeMethod('inTry');
  } on Object catch (outer, st) {
    outer.invokeMethod('shadowedByCatch');
  }
}
''');

        final result = indexBridges(root.path);

        // catch 예외 파라미터 `outer`가 catch 스코프에 선언되어 동명 최상위 채널을
        // 가린다. try 본문의 호출은 채널로 해결되고 catch 본부는 미해결로 강등된다.
        expect(created(result), ['outerChan']);
        expect(invokes(result), ['inTry@outerChan']);
        expect(
          result.limitations.any(
            (s) => s.startsWith('unresolved-receiver-invocations:'),
          ),
          isTrue,
        );
      },
    );

    test('a for-each loop variable shadows an outer channel', () async {
      final root = await writeFixture('bridge-for-shadow.', '''
import 'package:flutter/services.dart';
final outer = MethodChannel('loopChan');
void go() {
  outer.invokeMethod('beforeLoop');
  final items = [1];
  for (final outer in items) {
    outer.invokeMethod('shadowedByLoop');
  }
}
''');

      final result = indexBridges(root.path);

      // for-each 루프 변수 `outer`가 루프 스코프에 선언되어 최상위 채널을 가린다.
      expect(created(result), ['loopChan']);
      expect(invokes(result), ['beforeLoop@loopChan']);
      expect(
        result.limitations.any(
          (s) => s.startsWith('unresolved-receiver-invocations:'),
        ),
        isTrue,
      );
    });

    test('a closure parameter shadows an outer channel', () async {
      final root = await writeFixture('bridge-closure-shadow.', '''
import 'package:flutter/services.dart';
void go() {
  final c = MethodChannel('closureChan');
  c.invokeMethod('beforeClosure');
  final invoke = (c) => c.invokeMethod('shadowedByParam');
  invoke('x');
}
''');

      final result = indexBridges(root.path);

      // 클로저 파라미터 `c`가 파라미터 스코프에 선언되어 포획된 동명 채널을 가린다.
      expect(created(result), ['closureChan']);
      expect(invokes(result), ['beforeClosure@closureChan']);
      expect(
        result.limitations.any(
          (s) => s.startsWith('unresolved-receiver-invocations:'),
        ),
        isTrue,
      );
    });
  });

  group('bridge channel resolution and determinism', () {
    test(
      'an inline channel construction receives its own invocation',
      () async {
        final root = await writeFixture('bridge-inline.', '''
import 'package:flutter/services.dart';
void go() {
  MethodChannel('inlineChan').invokeMethod('inline');
}
''');

        final result = indexBridges(root.path);

        // 수신자가 SimpleIdentifier가 아니면 인라인 생성에서 채널을 해석한다.
        expect(created(result), ['inlineChan']);
        expect(invokes(result), ['inline@inlineChan']);
      },
    );

    test('a prefixed flutter services import resolves its channel', () async {
      final root = await writeFixture('bridge-prefix.', '''
import 'package:flutter/services.dart' as svc;
final c = svc.MethodChannel('prefixedChan');
void go() => c.invokeMethod('prefixed');
''');

      final result = indexBridges(root.path);

      // `as svc` 접두 import의 MethodChannel도 flutter 채널로 인식된다.
      expect(created(result), ['prefixedChan']);
      expect(invokes(result), ['prefixed@prefixedChan']);
    });

    test(
      'two invocations on one line sort by column deterministically',
      () async {
        final root = await writeFixture('bridge-column.', '''
import 'package:flutter/services.dart';
final c = MethodChannel('cmpChan');
void go() { c.invokeMethod('a'); c.invokeMethod('b'); }
''');

        final result = indexBridges(root.path);

        // 같은 경로·같은 줄의 두 사실은 열 순서로 결정적으로 정렬된다.
        expect(invokes(result), ['a@cmpChan', 'b@cmpChan']);
      },
    );
  });

  test(
    'indexBridges rejects a project root not containing the package root',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'bridge-contain.',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final root = Directory('${workspace.path}/package');
      final outside = Directory('${workspace.path}/elsewhere');
      await root.create();
      await outside.create();
      await File('${root.path}/channel.dart').writeAsString('void main() {}\n');

      // CLI가 usage(64)로 먼저 막지만, 라이브러리 호출자의 계약 위반도
      // ArgumentError로 크게 실패한다(이중 방어 — location.path 탈출 방지).
      expect(
        () => indexBridges(root.path, projectRootPath: outside.path),
        throwsArgumentError,
      );
    },
  );
}

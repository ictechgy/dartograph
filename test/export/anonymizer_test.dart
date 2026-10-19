import 'dart:math';

import 'package:dartograph/dartograph.dart';
import 'package:dartograph/src/export/anonymizer.dart';
import 'package:test/test.dart';

void main() {
  GraphSnapshot sample() => GraphSnapshot(
    nodes: [
      GraphNode(
        id: 'project:lib/src/repo.dart',
        sourceUri: 'project:lib/src/repo.dart',
        isLibrary: true,
      ),
      GraphNode(
        id: 'project:lib/src/repo.dart::TaxCalculator.net',
        sourceUri: 'project:lib/src/repo.dart',
        line: 7,
      ),
      GraphNode(
        id: 'package:secret_app/lib/api.dart::Client.connect',
        sourceUri: 'package:secret_app/lib/api.dart',
        isTypeDeclaration: true,
      ),
      GraphNode(id: '<no-library>', isLibrary: true),
    ],
    edges: const [
      GraphEdge(
        sourceId: 'project:lib/src/repo.dart::TaxCalculator.net',
        targetId: 'package:secret_app/lib/api.dart::Client.connect',
        kind: EdgeKind.call,
      ),
    ],
  );

  test('anonymization is deterministic across runs and injective', () {
    final first = GraphAnonymizer.forGraph(sample());
    final second = GraphAnonymizer.forGraph(sample());

    for (final anonymizer in [first, second]) {
      expect(
        anonymizer.anonymizeId('project:lib/src/repo.dart::TaxCalculator.net'),
        anonymizer.anonymizeId('project:lib/src/repo.dart::TaxCalculator.net'),
      );
    }
    expect(
      first.anonymizeId('project:lib/src/repo.dart::TaxCalculator.net'),
      second.anonymizeId('project:lib/src/repo.dart::TaxCalculator.net'),
    );

    // 서로 다른 식별 문자열은 결코 같은 토큰으로 접히지 않는다.
    final mapped = {
      first.anonymizeId('project:lib/src/repo.dart'),
      first.anonymizeId('package:secret_app/lib/api.dart'),
      first.anonymizeId('project:lib/src/repo.dart::TaxCalculator.net'),
      first.anonymizeId('package:secret_app/lib/api.dart::Client.connect'),
    };
    expect(mapped, hasLength(4));
  });

  test('structure, extensions, and common vocabulary survive', () {
    final anonymizer = GraphAnonymizer.forGraph(sample());

    final library = anonymizer.anonymizeId('package:secret_app/lib/api.dart');
    // 스킴·디렉터리 계층·확장자는 보존되고 관용 디렉터리(lib)는 그대로다.
    expect(library, matches(r'^package:s\d+/lib/s\d+\.dart$'));

    final member = anonymizer.anonymizeId(
      'project:lib/src/repo.dart::TaxCalculator.net',
    );
    // `::` 구분과 멤버의 점 구조는 유지된다(식별자만 치환).
    expect(member, matches(r'^project:lib/src/s\d+\.dart::s\d+\.s\d+$'));

    // dartograph 고정 어휘는 치환하지 않는다.
    expect(anonymizer.anonymizeId('<no-library>'), '<no-library>');

    // 확장자 규칙: 끝의 `.dart`만 보존하고 나머지 점 구분 부분은 치환한다
    // (a.spec.dart → s?.s?.dart).
    expect(
      anonymizer.anonymizeUri('project:lib/generated/a.spec.dart'),
      matches(r'^project:lib/s\d+/s\d+\.s\d+\.dart$'),
    );

    // 같은 세그먼트는 어디서나 같은 토큰(ID와 sourceURI가 일치).
    expect(anonymizer.anonymizeUri('package:secret_app/lib/api.dart'), library);
  });

  test('free text replaces whole registered paths only', () {
    final anonymizer = GraphAnonymizer.forGraph(sample());

    // 그래프에 실린 경로 전체는 치환된다(스킴 없는 상대 형태도).
    final mapped = anonymizer.anonymizeText(
      'configured-entry-point-without-main: lib/src/repo.dart',
    );
    expect(mapped, contains('s'));
    expect(mapped, isNot(contains('lib/src/repo.dart')));
    expect(mapped, startsWith('configured-entry-point-without-main: lib/src/'));

    // 그래프에 없는 경로·일반 단어는 그대로 남는다(과다치환 방지).
    expect(
      anonymizer.anonymizeText('some unrelated words about taxes'),
      'some unrelated words about taxes',
    );
    expect(anonymizer.anonymizeText('unknown/path.dart'), 'unknown/path.dart');
  });

  test('output depends on the sorted graph, not insertion order', () {
    // 같은 정점 집합을 역순으로 넣어도 스냅샷이 정렬해 같은 치환표를 낸다.
    final graph = CodeGraph();
    for (final node in sample().nodes.reversed) {
      graph.addNode(
        GraphNode(
          id: node.id,
          sourceUri: node.sourceUri,
          line: node.line,
          column: node.column,
          synthesized: node.synthesized,
          isLibrary: node.isLibrary,
          isTypeDeclaration: node.isTypeDeclaration,
          isAbstract: node.isAbstract,
          isEnumConstant: node.isEnumConstant,
        ),
      );
    }

    final first = GraphAnonymizer.forGraph(sample());
    final second = GraphAnonymizer.forGraph(graph.snapshot());
    for (final id in [
      'project:lib/src/repo.dart',
      'project:lib/src/repo.dart::TaxCalculator.net',
      'package:secret_app/lib/api.dart::Client.connect',
    ]) {
      expect(first.anonymizeId(id), second.anonymizeId(id));
    }
  });

  test('setter suffixes, :: filenames, and unknown schemes', () {
    final anonymizer = GraphAnonymizer.forGraph(sample());

    // setter 접미 `=`는 확장자와 대칭으로 보존된다(식별자만 치환).
    expect(
      anonymizer.anonymizeId('project:lib/src/repo.dart::TaxCalculator.value='),
      matches(r'^project:lib/src/s\d+\.dart::s\d+\.s\d+=$'),
    );

    // 파일명에 `::`가 있으면 첫 `::`를 구분으로 본다(사영 접힘 `_libraryOf`와
    // 같은 관례) — 라이브러리 부분이 파일명의 `::` 앞에서 끊기지만 치환은
    // 여전히 결정적·단사다. 근본 해소는 html 분류처럼 명시 종류가 필요하다.
    final weird = anonymizer.anonymizeId(
      'package:secret_app/lib/weird::name.dart::Decl',
    );
    expect(weird, matches(r'^package:s\d+/lib/s\d+::s\d+\.s\d+$'));
    expect(weird, contains('::'));
    expect(weird, isNot(contains('weird')));

    // dartograph가 쓰지 않는 스킴 모양 접두는 식별 문자열로 치환된다.
    expect(
      anonymizer.anonymizeUri('myapp:something/else.dart'),
      isNot(startsWith('myapp:')),
    );
  });

  test('dotted file and directory names keep only known Dart extensions', () {
    final anonymizer = GraphAnonymizer.forGraph(
      GraphSnapshot(
        nodes: [
          GraphNode(
            id: 'project:lib/com.acme.internal/acme.billing_gateway.dart',
            isLibrary: true,
          ),
          GraphNode(id: 'project:lib/x.g.dart', isLibrary: true),
        ],
        edges: const [],
      ),
    );

    // 첫 마침표 뒤를 원문으로 두면 회사·모듈 이름이 거의 그대로 남는다.
    final library = anonymizer.anonymizeId(
      'project:lib/com.acme.internal/acme.billing_gateway.dart',
    );
    expect(
      library,
      matches(r'^project:lib/s\d+\.s\d+\.s\d+/s\d+\.s\d+\.dart$'),
    );
    for (final word in ['com', 'acme', 'internal', 'billing', 'gateway']) {
      expect(library, isNot(contains(word)));
    }

    // 생성 파일 접미는 확장자로 보존된다(x.g.dart → s?.g.dart).
    expect(
      anonymizer.anonymizeId('project:lib/x.g.dart'),
      matches(r'^project:lib/s\d+\.g\.dart$'),
    );
    for (final suffix in const [
      '.freezed.dart',
      '.pb.dart',
      '.pbenum.dart',
      '.pbgrpc.dart',
      '.pbjson.dart',
      '.pbserver.dart',
    ]) {
      expect(
        anonymizer.anonymizeUri('project:lib/order$suffix'),
        matches('^project:lib/s\\d+${RegExp.escape(suffix)}\$'),
      );
    }

    // 목록 밖의 접미와 Dart가 아닌 확장자는 식별 문자열로 치환된다.
    expect(
      anonymizer.anonymizeUri('project:lib/acme.mocks.dart'),
      matches(r'^project:lib/s\d+\.s\d+\.dart$'),
    );
    expect(
      anonymizer.anonymizeUri('project:lib/acme.secrets.yaml'),
      matches(r'^project:lib/s\d+\.s\d+\.s\d+$'),
    );

    // USAGE의 예시: 같은 부분(acme)은 디렉터리와 파일 이름에서 같은 토큰이다.
    const usage = 'project:lib/com.acme.internal/acme.billing.dart';
    final single = GraphAnonymizer.forGraph(
      GraphSnapshot(
        nodes: [GraphNode(id: usage, isLibrary: true)],
        edges: const [],
      ),
    );
    expect(single.anonymizeId(usage), 'project:lib/s1.s2.s3/s2.s5.dart');
  });

  test('part-wise replacement stays injective and deterministic', () {
    // 점 구분 부분을 따로 치환해도 서로 다른 이름이 한 출력으로 접히지 않는다.
    // 관용 어휘·확장자 조각·빈 부분·토큰 모양 이름을 섞어 경계를 넓게 훑는다.
    const pieces = [
      'a',
      'acme',
      'lib',
      'main',
      'dart',
      'g',
      'pb',
      'freezed',
      's1',
      '',
    ];
    final random = Random(20261019);
    String randomName() {
      final count = random.nextInt(4) + 1;
      final parts = [
        for (var j = 0; j < count; j++) pieces[random.nextInt(pieces.length)],
      ];
      return parts.join('.');
    }

    final ids = {
      for (var i = 0; i < 600; i++) 'project:lib/${randomName()}',
    }.toList();
    GraphAnonymizer build() => GraphAnonymizer.forGraph(
      GraphSnapshot(
        nodes: [for (final id in ids) GraphNode(id: id, isLibrary: true)],
        edges: const [],
      ),
    );

    final first = build();
    final mapped = [for (final id in ids) first.anonymizeId(id)];
    expect(mapped.toSet(), hasLength(ids.length));
    final second = build();
    expect([for (final id in ids) second.anonymizeId(id)], mapped);
  });
}

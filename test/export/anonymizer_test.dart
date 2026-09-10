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

    // 확장자 규칙: 첫 마침표 뒤는 그대로 둔다(a.spec.dart → s?.spec.dart).
    expect(
      anonymizer.anonymizeUri('project:lib/generated/a.spec.dart'),
      matches(r'^project:lib/s\d+/s\d+\.spec\.dart$'),
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
}

import 'dart:convert';

import 'package:dartograph_analysis_plugin/src/report_store.dart';
import 'package:test/test.dart';

void main() {
  group('stripScheme', () {
    test('project: 접두를 벗기고 다른 스킴은 null이다', () {
      expect(stripScheme('project:lib/a.dart'), 'lib/a.dart');
      expect(stripScheme('lib/a.dart'), 'lib/a.dart');
      expect(stripScheme('package:dep/x.dart'), isNull);
      expect(stripScheme(''), isNull);
      expect(stripScheme(null), isNull);
    });
  });

  group('safeRelative', () {
    test('루트 밖 경로를 배제한다', () {
      expect(safeRelative('lib/a.dart'), 'lib/a.dart');
      expect(safeRelative('../x.dart'), isNull);
      expect(safeRelative('a/../b.dart'), isNull);
      expect(safeRelative('/abs/x.dart'), isNull);
      expect(safeRelative('C:/x.dart'), isNull);
    });
  });

  group('parseDead', () {
    test('source·line·column을 발견 위치로 변환한다', () {
      final document =
          jsonDecode('''
        {"findings":[
          {"kind":"declaration","source":"project:lib/unused.dart",
           "line":4,"column":7,"reason":"unreachable from all retention roots"},
          {"kind":"file","source":"project:lib/orphan.dart",
           "reason":"no reachable declaration or reachable library import"},
          {"kind":"declaration","source":"package:dep/x.dart","reason":"skip"},
          {"kind":"file","source":"project:../outside.dart","reason":"skip"}
        ],"report":"dead"}
      ''')
              as Map<String, Object?>;
      final byFile = parseDead(document);
      expect(byFile.keys, containsAll(['lib/unused.dart', 'lib/orphan.dart']));
      expect(byFile['lib/unused.dart']!.single.line, 4);
      expect(byFile['lib/unused.dart']!.single.column, 7);
      expect(
        byFile['lib/unused.dart']!.single.message,
        contains('unreachable from all retention roots'),
      );
      // 파일 수준 발견은 행·열이 없으므로 1행 1열로 둔다.
      expect(byFile['lib/orphan.dart']!.single.line, 1);
    });
  });

  group('parseDup', () {
    test('양 인스턴스를 발견으로 변환하고 상대 위치를 메시지에 넣는다', () {
      final document =
          jsonDecode('''
        {"findings":[{"tokenCount":80,"instances":[
          {"source":"project:lib/a.dart","startLine":3,"endLine":20},
          {"source":"project:lib/b.dart","startLine":8,"endLine":25}
        ]}],"report":"dup"}
      ''')
              as Map<String, Object?>;
      final byFile = parseDup(document);
      expect(byFile['lib/a.dart']!.single.endLine, 20);
      expect(byFile['lib/a.dart']!.single.message, contains('lib/b.dart:8'));
      expect(byFile['lib/b.dart']!.single.message, contains('lib/a.dart:3'));
      expect(byFile['lib/a.dart']!.single.message, contains('80 tokens'));
    });

    test('패키지 밖 인스턴스는 발견을 만들지 않지만 위치는 메시지에 남는다', () {
      final document =
          jsonDecode('''
        {"findings":[{"tokenCount":50,"instances":[
          {"source":"project:lib/a.dart","startLine":1,"endLine":5},
          {"source":"package:dep/x.dart","startLine":1,"endLine":5}
        ]}],"report":"dup"}
      ''')
              as Map<String, Object?>;
      final byFile = parseDup(document);
      expect(byFile.keys, ['lib/a.dart']);
      expect(byFile['lib/a.dart']!.single.message, contains('package:dep'));
    });
  });
}

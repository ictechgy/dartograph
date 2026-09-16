import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/edit/dart/dart_fix_kind_priority.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';

/// `// dartograph:ignore` 주석을 선언 위에 다는 quick fix다.
/// 억제는 저장소 작성자의 결정으로 그래프에 기록된다 — 삭제가 아닌 억제다.
class AddDartographIgnore extends ResolvedCorrectionProducer {
  /// 프로듀서를 만든다.
  AddDartographIgnore({required super.context});

  static const _kind = FixKind(
    'dartograph.fix.addIgnore',
    DartFixKindPriority.standard,
    "Add '// dartograph:ignore'",
  );

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => _kind;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    // 억제 주석은 선언에만 적용된다 — 파일 수준 발견이나 식 안쪽 위치에는
    // 제안하지 않는다.
    if (node.thisOrAncestorOfType<Declaration>() == null) return;
    final offset = diagnosticOffset;
    if (offset == null) return;
    final lineInfo = unitResult.lineInfo;
    final line = lineInfo.getLocation(offset).lineNumber - 1;
    final lineStart = lineInfo.getOffsetOfLine(line);
    final content = unitResult.content;
    // 바로 위 줄에 이미 억제 주석이 있으면 다시 제안하지 않는다.
    if (line > 0) {
      final aboveStart = lineInfo.getOffsetOfLine(line - 1);
      if (content
          .substring(aboveStart, lineStart)
          .contains('dartograph:ignore')) {
        return;
      }
    }
    var indentEnd = lineStart;
    while (indentEnd < content.length &&
        (content[indentEnd] == ' ' || content[indentEnd] == '\t')) {
      indentEnd++;
    }
    final indent = content.substring(lineStart, indentEnd);
    await builder.addDartFileEdit(file, (editBuilder) {
      editBuilder.addSimpleInsertion(
        lineStart,
        '$indent// dartograph:ignore\n',
      );
    });
  }
}

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/edit/dart/dart_fix_kind_priority.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
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

  /// CLI 매처와 같은 지시문 판정이다 — `//` 접두를 벗긴 본문이 마커로 시작한다.
  static final _directive = RegExp(r'^dartograph:ignore(?![A-Za-z0-9_])');

  @override
  CorrectionApplicability get applicability =>
      CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => _kind;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    // 억제 주석은 선언에만 적용된다 — 식 안쪽 위치에는 제안하지 않는다.
    // 1:1 파일 수준 발견과 첫 선언 시작 위치는 진단 offset만으로 구분할 수 없다.
    final decl = node.thisOrAncestorOfType<Declaration>();
    if (decl == null) return;
    if (_alreadySuppressed(decl)) return;

    // doc comment·metadata를 포함한 선언 블록의 맨 위에 넣는다 — 주석 사이에
    // 끼면 doc comment와 선언의 결속이 끊긴다. CLI는 다음 실토큰의 주석 사슬을
    // 보기 때문에 블록 위에 둬도 같은 선언의 지시문으로 인식된다.
    final top =
        decl.documentationComment?.offset ??
        (decl.metadata.isNotEmpty ? decl.metadata.first.offset : decl.offset);
    final lineInfo = unitResult.lineInfo;
    final lineStart = lineInfo.getOffsetOfLine(
      lineInfo.getLocation(top).lineNumber - 1,
    );
    final content = unitResult.content;
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

  /// 선언의 실토큰 주석 사슬에 이미 지시문이 있으면 true다. metadata의 `@`와
  /// 주석·metadata 뒤 첫 키워드 두 anchor를 본다 — doc comment 위의 마커도
  /// 같은 사슬에 들어가므로 이 검사가 잡는다.
  static bool _alreadySuppressed(Declaration decl) {
    final anchors = <Token?>[
      if (decl.metadata.isNotEmpty) decl.metadata.beginToken,
      decl.firstTokenAfterCommentAndMetadata,
    ];
    for (final anchor in anchors) {
      var comment = anchor?.precedingComments;
      while (comment != null) {
        final lexeme = comment.lexeme.trim();
        if (lexeme.startsWith('//') &&
            !lexeme.startsWith('///') &&
            _directive.hasMatch(lexeme.substring(2).trim())) {
          return true;
        }
        comment = comment.next as CommentToken?;
      }
    }
    return false;
  }
}

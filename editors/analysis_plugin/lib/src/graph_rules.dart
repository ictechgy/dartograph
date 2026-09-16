import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/source/line_info.dart';

import 'report_store.dart';

/// 유닛이 속한 패키지 루트다 — 워크스페이스 패키지 정보 또는 pubspec 상향 탐색.
String? packageRootOf(RuleContext context, RuleContextUnit unit) {
  final root = context.package?.root.path;
  if (root != null) return root;
  var directory = unit.file.parent;
  while (true) {
    if (directory.getFile('pubspec.yaml').exists) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}

/// 유닛의 패키지 상대 경로다. 루트 밖이면 null이다.
String? relativePathOf(String root, String fullPath) {
  final prefix = root.endsWith('/') ? root : '$root/';
  if (!fullPath.startsWith(prefix)) return null;
  return fullPath.substring(prefix.length);
}

/// dead 발견을 진단으로 보고한다. 발견은 그래프 근거이며 삭제 판정이 아니다.
class DeadCodeRule extends AnalysisRule {
  /// 규칙을 만든다.
  DeadCodeRule()
    : super(
        name: 'dartograph_dead_code',
        description:
            'Reports declarations and files unreachable from dartograph '
            'retention roots. Findings carry evidence, not a deletion verdict.',
      );

  /// 이 규칙이 보고하는 진단 코드다.
  static const LintCode code = LintCode(
    'dartograph_dead_code',
    '{0}',
    correctionMessage:
        'Verify the evidence before deleting, or suppress with '
        "'// dartograph:ignore'.",
    severity: DiagnosticSeverity.WARNING,
  );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _Visitor(this, context));
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.context);

  final DeadCodeRule rule;
  final RuleContext context;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final unit = context.currentUnit;
    if (unit == null) return;
    final root = packageRootOf(context, unit);
    if (root == null) return;
    final report = ReportCache.reportFor(root);
    if (report == null) return;
    final relative = relativePathOf(root, unit.file.path);
    if (relative == null) return;
    for (final finding in report.dead[relative] ?? const <PluginFinding>[]) {
      final offset =
          unit.unit.lineInfo.getOffsetOfLine(finding.line - 1) +
          finding.column -
          1;
      rule.reportAtOffset(
        offset.clamp(0, unit.content.length),
        1,
        arguments: [finding.message],
      );
    }
  }
}

/// dup 발견을 정보 진단으로 보고한다. 블록은 검토 후보이며 병합 지시가 아니다.
class DuplicateBlockRule extends AnalysisRule {
  /// 규칙을 만든다.
  DuplicateBlockRule()
    : super(
        name: 'dartograph_duplicate_block',
        description:
            'Reports token-structural duplicate blocks found by dartograph. '
            'Findings are review candidates, not merge instructions.',
      );

  /// 이 규칙이 보고하는 진단 코드다.
  static const LintCode code = LintCode(
    'dartograph_duplicate_block',
    '{0}',
    correctionMessage: 'Review both locations before refactoring.',
  );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _DupVisitor(this, context));
  }
}

class _DupVisitor extends SimpleAstVisitor<void> {
  _DupVisitor(this.rule, this.context);

  final DuplicateBlockRule rule;
  final RuleContext context;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final unit = context.currentUnit;
    if (unit == null) return;
    final root = packageRootOf(context, unit);
    if (root == null) return;
    final report = ReportCache.reportFor(root);
    if (report == null) return;
    final relative = relativePathOf(root, unit.file.path);
    if (relative == null) return;
    for (final finding in report.dup[relative] ?? const <PluginFinding>[]) {
      final start = unit.unit.lineInfo.getOffsetOfLine(finding.line - 1);
      final endLine = finding.endLine ?? finding.line;
      final lastLine = (endLine - 1).clamp(0, unit.unit.lineInfo.lineCount - 1);
      final end =
          unit.unit.lineInfo.getOffsetOfLine(lastLine) +
          _lineLength(unit.content, lastLine, unit.unit.lineInfo);
      rule.reportAtOffset(
        start.clamp(0, unit.content.length),
        (end - start).clamp(1, unit.content.length),
        arguments: [finding.message],
      );
    }
  }

  /// 마지막 토큰 행의 끝까지 블록을 칠한다 — 행 시작점까지만 칠하면 범위가 짧다.
  static int _lineLength(String content, int zeroLine, LineInfo lineInfo) {
    final start = lineInfo.getOffsetOfLine(zeroLine);
    final next = zeroLine + 1 < lineInfo.lineCount
        ? lineInfo.getOffsetOfLine(zeroLine + 1)
        : content.length;
    return next - start;
  }
}

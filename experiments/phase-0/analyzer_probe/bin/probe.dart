import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

/// Runs the Phase 0 analyzer probe for one package root.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run bin/probe.dart <package-root>');
    exitCode = 64;
    return;
  }

  try {
    await _run(arguments.single);
  } on FileSystemException {
    stderr.writeln('Package root does not exist or cannot be read.');
    exitCode = 2;
  }
}

Future<void> _run(String rootArgument) async {
  final root = Directory(rootArgument).absolute.resolveSymbolicLinksSync();
  final stopwatch = Stopwatch()..start();
  final collection = AnalysisContextCollection(includedPaths: [root]);
  final generatedFiles = <Map<String, Object?>>[];
  var files = 0;
  var declarations = 0;
  var references = 0;
  var diagnostics = 0;
  final diagnosticCounts = <String, int>{};
  final diagnosticFiles = <String>{};
  final declarationIds = <String>[];
  final referenceIds = <String>[];

  try {
    for (final path in _dartFilesUnder(root, collection)) {
      final context = _contextIncluding(collection, path);
      final result = await context.currentSession.getResolvedUnit(path);
      if (result is! ResolvedUnitResult) {
        continue;
      }

      files++;
      diagnostics += result.diagnostics.length;
      final relativePath = path.substring(root.length + 1);
      if (result.diagnostics.isNotEmpty) {
        diagnosticFiles.add(relativePath);
      }
      for (final diagnostic in result.diagnostics) {
        final key =
            '${diagnostic.severity.name}:'
            '${diagnostic.diagnosticCode.lowerCaseName}';
        diagnosticCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
      }
      final counter = _FactCounter(root);
      result.unit.accept(counter);
      declarations += counter.declarations;
      references += counter.references;
      declarationIds.addAll(counter.declarationIds);
      referenceIds.addAll(counter.referenceIds);

      if (_isGenerated(relativePath)) {
        generatedFiles.add({
          'path': relativePath,
          'libraryUri': result.libraryElement.uri.toString(),
          'generated': true,
        });
      }
    }
  } finally {
    await collection.dispose();
  }

  stopwatch.stop();
  declarationIds.sort();
  referenceIds.sort();
  final sortedDiagnosticCounts = <String, int>{};
  final diagnosticKeys = diagnosticCounts.keys.toList()..sort();
  for (final key in diagnosticKeys) {
    sortedDiagnosticCounts[key] = diagnosticCounts[key]!;
  }
  final sortedDiagnosticFiles = diagnosticFiles.toList()..sort();
  stdout.writeln(
    jsonEncode({
      'declarationIds': declarationIds,
      'declarations': declarations,
      'diagnosticCounts': sortedDiagnosticCounts,
      'diagnosticFiles': sortedDiagnosticFiles,
      'diagnostics': diagnostics,
      'elapsedMs': stopwatch.elapsedMilliseconds,
      'files': files,
      'generatedFiles': generatedFiles,
      'referenceIds': referenceIds,
      'references': references,
    }),
  );
}

AnalysisContext _contextIncluding(
  AnalysisContextCollection collection,
  String path,
) {
  try {
    return collection.contextFor(path);
  } on StateError {
    final contexts = [...collection.contexts]
      ..sort(
        (left, right) => right.contextRoot.root.path.length.compareTo(
          left.contextRoot.root.path.length,
        ),
      );
    return contexts.firstWhere(
      (context) => path.startsWith('${context.contextRoot.root.path}/'),
    );
  }
}

List<String> _dartFilesUnder(
  String root,
  AnalysisContextCollection collection,
) {
  final paths = <String>{};
  for (final context in collection.contexts) {
    paths.addAll(
      context.contextRoot.analyzedFiles().where(
        (path) => path.endsWith('.dart') && path.startsWith('$root/'),
      ),
    );
  }

  final generatedPaths = Directory(root)
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .map((file) => file.path)
      .where((path) => _isGenerated(path))
      .where((path) {
        final relativePath = path.substring(root.length + 1);
        final segments = Uri.file(relativePath).pathSegments;
        return !segments.contains('.dart_tool') && !segments.contains('build');
      });
  paths.addAll(generatedPaths);

  final sortedPaths = paths.toList()..sort();
  return sortedPaths;
}

bool _isGenerated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.endsWith('.pb.dart');

final class _FactCounter extends GeneralizingAstVisitor<void> {
  _FactCounter(this.root);

  final String root;
  var declarations = 0;
  var references = 0;
  final declarationIds = <String>[];
  final referenceIds = <String>[];

  @override
  void visitDeclaration(Declaration node) {
    if (node.declaredFragment?.element case final element?
        when _isGraphElement(element)) {
      declarations++;
      declarationIds.add(_elementId(element, root));
    }
    super.visitDeclaration(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element?.baseElement;
    if (!node.inDeclarationContext() &&
        element != null &&
        _isGraphElement(element)) {
      references++;
      referenceIds.add(_elementId(element, root));
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNode(AstNode node) {
    node.visitChildren(this);
  }
}

bool _isGraphElement(Element element) =>
    element is ClassElement ||
    element is MixinElement ||
    element is EnumElement ||
    element is ExtensionElement ||
    element is ExtensionTypeElement ||
    element is TopLevelFunctionElement ||
    element is MethodElement ||
    element is FieldElement ||
    element is TopLevelVariableElement ||
    element is GetterElement ||
    element is SetterElement;

String _elementId(Element element, String root) {
  final libraryUri = _libraryId(element.library?.uri, root);
  final names = <String>[];
  Element? current = element;
  while (current != null && current is! LibraryElement) {
    final name = current.lookupName ?? current.displayName;
    if (name.isNotEmpty) {
      names.add(name);
    } else if (current is ExtensionElement) {
      names.add('<unnamed-extension@${current.firstFragment.offset}>');
    } else {
      names.add('<unnamed-${current.kind.name.toLowerCase()}>');
    }
    current = current.enclosingElement;
  }
  return '$libraryUri::${names.reversed.join('.')}';
}

String _libraryId(Uri? uri, String root) {
  if (uri == null) {
    return '<no-library>';
  }
  if (uri.scheme != 'file') {
    return uri.toString();
  }

  final path = File.fromUri(uri).absolute.path;
  if (path.startsWith('$root/')) {
    return 'project:${path.substring(root.length + 1)}';
  }
  return uri.toString();
}

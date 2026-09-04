import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import '../core/code_graph.dart';
import '../core/graph_edge.dart';
import '../core/graph_node.dart';

/// 공개 analyzer가 한 실행에서 조건부 구성 하나만 해석한다는 한계다.
enum AnalyzerLimitation {
  /// 조건부 import/export의 선택된 구성만 그래프에 들어간다.
  conditionalConfiguration,
}

/// analyzer 타입을 노출하지 않는 index 결과다.
final class AnalyzerGraphResult {
  /// 완성된 그래프와 적용된 분석 한계를 보존한다.
  const AnalyzerGraphResult({required this.graph, required this.limitations});

  /// resolved unit에서 얻은 선언과 관계다.
  final CodeGraph graph;

  /// 결과 해석 시 항상 알려야 하는 analyzer 한계다.
  final List<AnalyzerLimitation> limitations;
}

/// analyzer 14.3.0 resolved unit을 안정적인 core 그래프로 바꾼다.
final class AnalyzerGraphIndex {
  /// [rootPath] 아래 분석 대상과 제외된 생성 파일을 함께 색인한다.
  Future<AnalyzerGraphResult> index(String rootPath) async {
    final root = Directory(rootPath).absolute.resolveSymbolicLinksSync();
    final collection = AnalysisContextCollection(includedPaths: [root]);
    final units = <ResolvedUnitResult>[];
    try {
      for (final path in _dartFilesUnder(root, collection)) {
        final result = await _contextIncluding(
          collection,
          path,
        ).currentSession.getResolvedUnit(path);
        if (result is ResolvedUnitResult) units.add(result);
      }

      final graph = CodeGraph();
      for (final unit in units) {
        final libraryId = _libraryId(unit.libraryElement.uri, root);
        if (!graph.containsNode(libraryId)) {
          graph.addNode(GraphNode(id: libraryId));
        }
        unit.unit.accept(_DeclarationCollector(graph, root));
      }
      final libraries = <String, LibraryElement>{};
      for (final unit in units) {
        final libraryId = _libraryId(unit.libraryElement.uri, root);
        libraries.putIfAbsent(libraryId, () => unit.libraryElement);
      }
      final libraryIds = libraries.keys.toList()..sort();
      for (final libraryId in libraryIds) {
        final library = libraries[libraryId]!;
        for (final import in library.firstFragment.libraryImports) {
          final imported = import.importedLibrary;
          if (imported == null) continue;
          final target = _libraryId(imported.uri, root);
          if (graph.containsNode(target)) {
            graph.addEdge(
              GraphEdge(
                sourceId: libraryId,
                targetId: target,
                kind: EdgeKind.import,
              ),
            );
          }
        }
        for (final export in library.firstFragment.libraryExports) {
          final exported = export.exportedLibrary;
          if (exported == null) continue;
          final target = _libraryId(exported.uri, root);
          if (graph.containsNode(target)) {
            graph.addEdge(
              GraphEdge(
                sourceId: libraryId,
                targetId: target,
                kind: EdgeKind.export,
              ),
            );
          }
        }
      }
      for (final unit in units) {
        unit.unit.accept(_RelationshipCollector(graph, root));
      }
      final hasConditionalConfiguration = units.any(
        (unit) => unit.unit.directives.any(
          (directive) => switch (directive) {
            ImportDirective() => directive.configurations.isNotEmpty,
            ExportDirective() => directive.configurations.isNotEmpty,
            _ => false,
          },
        ),
      );
      return AnalyzerGraphResult(
        graph: graph,
        limitations: hasConditionalConfiguration
            ? const [AnalyzerLimitation.conditionalConfiguration]
            : const [],
      );
    } finally {
      await collection.dispose();
    }
  }
}

final class _DeclarationCollector extends GeneralizingAstVisitor<void> {
  _DeclarationCollector(this.graph, this.root);

  final CodeGraph graph;
  final String root;

  @override
  void visitDeclaration(Declaration node) {
    final element = node.declaredFragment?.element;
    if (element != null && _isGraphElement(element)) {
      final location = node
          .thisOrAncestorOfType<CompilationUnit>()!
          .lineInfo
          .getLocation(node.offset);
      final id = _elementId(element, root);
      if (!graph.containsNode(id)) {
        graph.addNode(
          GraphNode(
            id: id,
            sourceUri: _sourcePathId(
              element.firstFragment.libraryFragment!.source.fullName,
              root,
            ),
            line: location.lineNumber,
            column: location.columnNumber,
            synthesized: _isGenerated(
              element.firstFragment.libraryFragment!.source.fullName,
            ),
          ),
        );
      }
    }
    super.visitDeclaration(node);
  }
}

final class _RelationshipCollector extends GeneralizingAstVisitor<void> {
  _RelationshipCollector(this.graph, this.root);

  final CodeGraph graph;
  final String root;
  String? _owner;

  @override
  void visitDeclaration(Declaration node) {
    final previous = _owner;
    final element = node.declaredFragment?.element;
    if (element != null && _isGraphElement(element)) {
      _owner = _elementId(element, root);
      final enclosing = element.enclosingElement;
      if (enclosing != null && _isGraphElement(enclosing)) {
        _add(_elementId(enclosing, root), _owner!, EdgeKind.member);
      }
      if (element is InterfaceElement) {
        final supertype = element.supertype;
        if (supertype != null &&
            supertype.element.library.uri.scheme != 'dart') {
          _add(
            _owner!,
            _elementId(supertype.element, root),
            EdgeKind.inheritance,
          );
        }
        for (final type in element.interfaces) {
          _add(_owner!, _elementId(type.element, root), EdgeKind.implements);
        }
        for (final type in element.mixins) {
          _add(_owner!, _elementId(type.element, root), EdgeKind.mixin);
        }
      }
      if (element is ExecutableElement && enclosing is InterfaceElement) {
        final name = element.name;
        if (name != null) {
          for (final overridden in enclosing.inheritedMembers.values.where(
            (candidate) => candidate.name == name,
          )) {
            _add(
              _owner!,
              _elementId(overridden.baseElement, root),
              EdgeKind.override,
            );
          }
        }
      }
    }
    node.visitChildren(this);
    _owner = previous;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final owner = _owner;
    final element = _graphTarget(node.element);
    if (owner != null && !node.inDeclarationContext() && element != null) {
      final target = _callTarget(node, element);
      if (target != null && _isGraphElement(target)) {
        _add(
          owner,
          _elementId(target, root),
          _isCall(node) ? EdgeKind.call : EdgeKind.reference,
        );
      }
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final owner = _owner;
    final target = node.constructorName.element?.enclosingElement;
    if (owner != null && target != null && _isGraphElement(target)) {
      _add(owner, _elementId(target, root), EdgeKind.call);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final owner = _owner;
    final target = _graphTarget(node.writeElement);
    if (owner != null && target != null && _isGraphElement(target)) {
      _add(owner, _elementId(target, root), EdgeKind.reference);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final owner = _owner;
    final element = node.element?.baseElement;
    final parent = node.parent;
    final isStructural =
        parent is ExtendsClause ||
        parent is ImplementsClause ||
        parent is WithClause ||
        parent is ConstructorName;
    if (owner != null &&
        element != null &&
        !isStructural &&
        _isGraphElement(element)) {
      _add(owner, _elementId(element, root), EdgeKind.reference);
    }
    super.visitNamedType(node);
  }

  Element? _callTarget(SimpleIdentifier node, Element element) {
    final constructorName = node.thisOrAncestorOfType<ConstructorName>();
    if (constructorName != null) {
      return constructorName.element?.enclosingElement ?? element;
    }
    return element;
  }

  bool _isCall(SimpleIdentifier node) {
    final parent = node.parent;
    return (parent is MethodInvocation && parent.methodName == node) ||
        (parent is FunctionExpressionInvocation && parent.function == node) ||
        node.thisOrAncestorOfType<ConstructorName>() != null;
  }

  void _add(String source, String target, EdgeKind kind) {
    if (source != target &&
        graph.containsNode(source) &&
        graph.containsNode(target)) {
      graph.addEdge(GraphEdge(sourceId: source, targetId: target, kind: kind));
    }
  }
}

Element? _graphTarget(Element? element) {
  final base = element?.baseElement;
  return switch (base) {
    GetterElement() => base.variable,
    SetterElement() => base.variable,
    _ => base,
  };
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
      final sourceId = _sourceId(
        current.firstFragment.libraryFragment.source.uri,
        root,
      );
      names.add(
        '<unnamed-extension@$sourceId#${current.firstFragment.offset}>',
      );
    }
    current = current.enclosingElement;
  }
  return '$libraryUri::${names.reversed.join('.')}';
}

String _libraryId(Uri? uri, String root) {
  if (uri == null) return '<no-library>';
  if (uri.scheme != 'file') return uri.toString();
  return _sourceId(uri, root);
}

String _sourceId(Uri uri, String root) {
  if (uri.scheme != 'file') return uri.toString();
  return projectIdForPath(File.fromUri(uri).absolute.path, root);
}

String _sourcePathId(String path, String root) {
  return projectIdForPath(path, root);
}

/// [path]를 플랫폼 경로 구분자와 무관한 프로젝트 source ID로 바꾼다.
String projectIdForPath(String path, String root, {p.Context? context}) {
  final paths = context ?? p.context;
  final absolutePath = paths.normalize(paths.absolute(path));
  final absoluteRoot = paths.normalize(paths.absolute(root));
  if (!isPathWithinRoot(absolutePath, absoluteRoot, context: paths)) {
    return Uri.file(
      absolutePath,
      windows: paths.style == p.Style.windows,
    ).toString();
  }
  final relativePath = paths.relative(absolutePath, from: absoluteRoot);
  return 'project:${p.url.joinAll(paths.split(relativePath))}';
}

/// [path]가 [root] 자체이거나 그 아래인지 플랫폼 구분자에 맞춰 확인한다.
bool isPathWithinRoot(String path, String root, {p.Context? context}) {
  final paths = context ?? p.context;
  final absolutePath = paths.normalize(paths.absolute(path));
  final absoluteRoot = paths.normalize(paths.absolute(root));
  return paths.equals(absolutePath, absoluteRoot) ||
      paths.isWithin(absoluteRoot, absolutePath);
}

List<String> _dartFilesUnder(
  String root,
  AnalysisContextCollection collection,
) {
  final paths = <String>{};
  for (final context in collection.contexts) {
    paths.addAll(
      context.contextRoot.analyzedFiles().where(
        (path) => path.endsWith('.dart') && isPathWithinRoot(path, root),
      ),
    );
  }
  paths.addAll(
    Directory(root)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((file) => file.path)
        .where(_isGenerated)
        .where(
          (path) => !p
              .split(p.relative(path, from: root))
              .any((segment) => segment == '.dart_tool' || segment == 'build'),
        ),
  );
  return paths.toList()..sort();
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
        (a, b) => b.contextRoot.root.path.length.compareTo(
          a.contextRoot.root.path.length,
        ),
      );
    return contexts.firstWhere(
      (context) => isPathWithinRoot(path, context.contextRoot.root.path),
      orElse: () => throw StateError(
        'No analyzer context contains the generated source.',
      ),
    );
  }
}

bool _isGenerated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.endsWith('.pb.dart');

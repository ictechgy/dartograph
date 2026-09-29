import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import 'route_url_rules.dart';

/// 문자열 식을 URL 조각으로 푼 결과다.
final class ResolvedUrl {
  /// 필드를 받는다.
  const ResolvedUrl(this.parts);

  /// 리터럴·보간·query 꼬리 조각이다.
  final List<UrlPart> parts;

  /// 첫 조각이 감싸는 함수의 매개변수(또는 그 속성)에서 온 값인지다. 경로를
  /// 그대로 흘려보내는 선언되지 않은 래퍼 싱크(`http-wrapper-undeclared:`)를
  /// 세는 데 쓴다.
  bool get leadingParameter {
    final merged = mergeUrlLiterals(parts);
    final first = merged.isEmpty ? null : merged.first;
    return first is ValueUrlPart && first.fromParameter;
  }

  /// 모든 조각이 리터럴이면 이어 붙인 값, 아니면 null이다.
  String? get literal {
    final merged = mergeUrlLiterals(parts);
    if (merged.isEmpty) return '';
    if (merged.length != 1) return null;
    final only = merged.first;
    return only is LiteralUrlPart ? only.text : null;
  }
}

/// 프로젝트 전체에서 모은 값 선언이다 — 파일 밖 `final`·`const` 선언을 증명할 수
/// 있을 때 치환하는 데 쓴다.
final class ValueDeclarations {
  /// 빈 색인을 만든다.
  ValueDeclarations();

  final _initializers = <Element, Expression>{};

  /// [unit]의 최상위 변수·static 필드·초기식이 있는 final 인스턴스 필드를 모은다.
  ///
  /// final·const만 모은다 — 다시 대입될 수 있는 변수는 초기식만으로 값을 증명할
  /// 수 없다. 초기식이 있는 final 필드는 생성자가 다시 대입할 수 없다(컴파일 오류).
  void collect(CompilationUnit unit) =>
      unit.accept(_DeclarationCollector(this));

  /// 증명된 초기식이다.
  Expression? initializerOf(Element element) => _initializers[element];
}

final class _DeclarationCollector extends RecursiveAstVisitor<void> {
  _DeclarationCollector(this.target);

  final ValueDeclarations target;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final element = node.declaredFragment?.element;
    final initializer = node.initializer;
    final list = node.parent;
    final fixed =
        list is VariableDeclarationList && (list.isFinal || list.isConst);
    if (initializer != null &&
        fixed &&
        (element is TopLevelVariableElement || element is FieldElement)) {
      target._initializers[element!] = initializer;
    }
    super.visitVariableDeclaration(node);
  }
}

/// 문자열 식을 URL 조각으로 푸는 해석기다.
///
/// 문자열 리터럴·인접 문자열·보간·`+` 연결·상수(analyzer 상수 평가)·증명된
/// final 선언과 다시 대입되지 않는 지역 변수를 따라간다. 풀지 못한 식은 값
/// 조각으로 남긴다 — 추측해 리터럴로 만들지 않는다.
final class RouteValueResolver {
  /// 프로젝트 [declarations]로 해석기를 만든다.
  RouteValueResolver(this.declarations);

  /// 파일 밖 선언 색인이다.
  final ValueDeclarations declarations;

  static const _maxDepth = 12;

  /// [expression]을 조각으로 푼다.
  ResolvedUrl resolve(Expression expression) {
    return ResolvedUrl(_parts(expression, 0, <Element>{}));
  }

  List<UrlPart> _parts(
    Expression expression,
    int depth,
    Set<Element> visiting,
  ) {
    if (depth > _maxDepth) return [const ValueUrlPart()];
    final node = expression.unParenthesized;
    return switch (node) {
      SimpleStringLiteral(:final value) => [LiteralUrlPart(value)],
      AdjacentStrings(:final strings) => [
        for (final string in strings) ..._parts(string, depth + 1, visiting),
      ],
      StringInterpolation() => _interpolation(node, depth, visiting),
      BinaryExpression() when node.operator.lexeme == '+' => _concatenation(
        node,
        depth,
        visiting,
      ),
      _ => _reference(node, depth, visiting),
    };
  }

  List<UrlPart> _interpolation(
    StringInterpolation node,
    int depth,
    Set<Element> visiting,
  ) => [
    for (final element in node.elements)
      if (element is InterpolationString)
        LiteralUrlPart(element.value)
      else if (element is InterpolationExpression)
        ..._interpolated(element.expression, depth, visiting),
  ];

  /// 보간식 하나다. 증명된 query 꼬리 지역 변수는 꼬리 조각이 된다.
  List<UrlPart> _interpolated(
    Expression expression,
    int depth,
    Set<Element> visiting,
  ) {
    final local = _localVariable(expression);
    if (local != null && _isQueryTailLocal(expression, local)) {
      return [const QueryTailUrlPart()];
    }
    return _parts(expression, depth + 1, visiting);
  }

  List<UrlPart> _concatenation(
    BinaryExpression node,
    int depth,
    Set<Element> visiting,
  ) {
    final type = node.staticType;
    if (type == null || !type.isDartCoreString) {
      return [const ValueUrlPart()];
    }
    return [
      ..._parts(node.leftOperand, depth + 1, visiting),
      ..._interpolated(node.rightOperand, depth, visiting),
    ];
  }

  /// 식별자·속성 참조를 상수 값·증명된 초기식으로 푼다.
  List<UrlPart> _reference(Expression node, int depth, Set<Element> visiting) {
    final element = referencedVariable(node);
    final opaque = ValueUrlPart(fromParameter: _parameterDerived(node));
    if (element == null) return [opaque];
    final constant = _constantString(element);
    if (constant != null) return [LiteralUrlPart(constant)];
    if (!visiting.add(element)) return [opaque];
    try {
      final initializer = initializerOf(node, element);
      if (initializer == null) return [opaque];
      return _parts(initializer, depth + 1, visiting);
    } finally {
      visiting.remove(element);
    }
  }

  /// 증명된 [element]의 초기식이다. 파일 밖 final·const 선언과, [usage]를
  /// 감싸는 함수에서 다시 대입되지 않는 지역 변수만 돌려준다.
  Expression? initializerOf(Expression usage, VariableElement element) =>
      declarations.initializerOf(element) ?? _localInitializer(usage, element);

  String? _constantString(VariableElement element) {
    if (!element.isConst) return null;
    return element.computeConstantValue()?.toStringValue();
  }

  /// 다시 대입되지 않는 지역 변수의 초기식이다.
  Expression? _localInitializer(Expression usage, VariableElement element) {
    if (element is! LocalVariableElement) return null;
    final scope = _outermostBody(usage);
    if (scope == null) return null;
    final finder = _LocalFinder(element);
    scope.accept(finder);
    if (finder.assigned) return null;
    return finder.declaration?.initializer;
  }

  LocalVariableElement? _localVariable(Expression expression) {
    final element = referencedVariable(expression);
    return element is LocalVariableElement ? element : null;
  }

  /// 초기식의 비어 있지 않은 값이 모두 `?`로 시작하고 나머지가 빈 문자열인
  /// 지역 변수인지다(`compose.suffix`).
  bool _isQueryTailLocal(Expression usage, LocalVariableElement element) {
    final initializer = _localInitializer(usage, element);
    return initializer != null && _queryTail(initializer) != _Tail.no;
  }

  _Tail _queryTail(Expression expression) {
    final node = expression.unParenthesized;
    if (node is ConditionalExpression) {
      final left = _queryTail(node.thenExpression);
      final right = _queryTail(node.elseExpression);
      if (left == _Tail.no || right == _Tail.no) return _Tail.no;
      return left == _Tail.query || right == _Tail.query
          ? _Tail.query
          : _Tail.empty;
    }
    if (node is BinaryExpression && node.operator.lexeme == '+') {
      return _queryTail(node.leftOperand) == _Tail.query
          ? _Tail.query
          : _Tail.no;
    }
    final first = _firstLiteral(node);
    if (first == null) return _Tail.no;
    if (first.isEmpty && node is SimpleStringLiteral) return _Tail.empty;
    return first.startsWith('?') ? _Tail.query : _Tail.no;
  }

  String? _firstLiteral(Expression node) => switch (node) {
    SimpleStringLiteral(:final value) => value,
    StringInterpolation(:final elements) =>
      elements.firstOrNull is InterpolationString
          ? (elements.first as InterpolationString).value
          : null,
    AdjacentStrings(:final strings) => _firstLiteral(strings.first),
    _ => null,
  };
}

enum _Tail { no, empty, query }

/// 식이 매개변수나 매개변수의 속성(`endpoint.path`)인지다.
bool _parameterDerived(Expression expression) {
  final node = expression.unParenthesized;
  if (referencedVariable(node) is FormalParameterElement) return true;
  final target = switch (node) {
    PrefixedIdentifier(:final prefix) => prefix,
    PropertyAccess() => node.realTarget,
    _ => null,
  };
  return target != null && referencedVariable(target) is FormalParameterElement;
}

/// 식이 가리키는 변수 element다(getter는 그 변수로 바꾼다).
VariableElement? referencedVariable(Expression expression) {
  final element = switch (expression.unParenthesized) {
    SimpleIdentifier(:final element) => element,
    PrefixedIdentifier(:final element) => element,
    PropertyAccess(:final propertyName) => propertyName.element,
    _ => null,
  };
  final base = element?.baseElement;
  return switch (base) {
    GetterElement() => base.variable,
    VariableElement() => base,
    _ => null,
  };
}

/// [node]를 감싸는 가장 바깥 함수 본문이다 — 지역 변수 선언과 대입을 찾는 범위다.
FunctionBody? _outermostBody(AstNode node) {
  FunctionBody? found;
  for (AstNode? current = node; current != null; current = current.parent) {
    if (current is FunctionBody) found = current;
    final member =
        current is ClassMember ||
        (current is CompilationUnitMember && current.parent is CompilationUnit);
    if (member) break;
  }
  return found;
}

final class _LocalFinder extends RecursiveAstVisitor<void> {
  _LocalFinder(this.element);

  final LocalVariableElement element;
  VariableDeclaration? declaration;
  var assigned = false;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.declaredFragment?.element == element) declaration = node;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (node.writeElement?.baseElement == element) assigned = true;
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (node.writeElement?.baseElement == element) assigned = true;
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (node.writeElement?.baseElement == element) assigned = true;
    super.visitPrefixExpression(node);
  }
}

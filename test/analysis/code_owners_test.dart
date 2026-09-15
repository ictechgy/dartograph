import 'package:dartograph/src/analysis/code_owners.dart';
import 'package:test/test.dart';

/// CODEOWNERS 부분집합 파서·매처의 계약이다.
void main() {
  final owners = CodeOwners.parse('''
# comment
*.dart @dart-team

/lib/ @lib-team
/lib/src/** @src-team
/docs/*.md
lib/example.dart @special
''');

  test('comments and blank lines are ignored', () {
    expect(owners.rules, hasLength(5));
    expect(owners.rules.first.pattern, '*.dart');
  });

  test('the last matching rule wins', () {
    // `*.dart`도 매치하지만 뒤의 `/lib/`가 이긴다.
    expect(owners.ownersOf('lib/a.dart'), ['@lib-team']);
    // 뒤의 정확한 파일 규칙이 이긴다.
    expect(owners.ownersOf('lib/example.dart'), ['@special']);
    // 어느 깊이든 `*.dart`가 매치한다.
    expect(owners.ownersOf('main.dart'), ['@dart-team']);
  });

  test('anchored directory patterns match their subtree only', () {
    expect(owners.ownersOf('lib/src/x.dart'), ['@src-team']);
    // `/lib/`는 lib/ 아래만 매치하고, 다른 디렉터리의 이름은 아니다.
    expect(owners.ownersOf('vendor/lib/x.dart'), ['@dart-team']);
  });

  test('a rule with no owners clears ownership instead of falling back', () {
    // `/docs/*.md`가 매치하고 소유자가 없으므로 앞선 규칙으로 내려가지 않는다.
    expect(owners.ownersOf('docs/readme.md'), isEmpty);
  });

  test('paths with no matching rule are unowned', () {
    expect(owners.ownersOf('assets/logo.png'), isEmpty);
  });

  test('question mark matches one non-slash character', () {
    final single = CodeOwners.parse('lib/a?.dart @one');
    expect(single.ownersOf('lib/a1.dart'), ['@one']);
    expect(single.ownersOf('lib/a12.dart'), isEmpty);
  });

  test('invalid-only input parses to no rules', () {
    expect(CodeOwners.parse('# just a comment\n\n').rules, isEmpty);
    expect(CodeOwners.parse('/ @root\n').rules, isEmpty);
  });
}

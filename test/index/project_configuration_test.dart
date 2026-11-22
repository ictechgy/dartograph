import 'dart:io';

import 'package:dartograph/src/core/config_source.dart';
import 'package:dartograph/src/index/project_configuration.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// 설정 해석의 형식 오류를 고칠 파일을 짚는 실패로 바꾸는 경계를 고정한다.
///
/// 이 경계가 없으면 `dartograph.yaml`·`pubspec.yaml`의 오류가 CLI에서 원인을 알 수
/// 없는 `unable to index the package`로만 보였다.
void main() {
  test('a plain format error names the file it came from', () {
    expect(
      () => readProjectConfiguration<void>(
        'dartograph.yaml',
        () => throw const FormatException('entry_points must be a list'),
      ),
      throwsA(
        isA<ProjectConfigurationException>().having(
          (error) => error.message,
          'message',
          'invalid dartograph.yaml: entry_points must be a list',
        ),
      ),
    );
  });

  test('a YAML syntax error carries the 1-based line and column', () {
    // 둘째 줄 첫 열에서 닫는 괄호 대신 파일 끝을 만난다. 파서 문구만으로는
    // 어디를 고칠지 알 수 없다.
    expect(
      () => readProjectConfiguration(
        'packages/a/pubspec.yaml',
        () => loadYaml('name: a\nenvironment: [\n'),
      ),
      throwsA(
        isA<ProjectConfigurationException>().having(
          (error) => error.message,
          'message',
          allOf(
            startsWith('invalid packages/a/pubspec.yaml: '),
            endsWith(' (line 3, column 1)'),
          ),
        ),
      ),
    );
  });

  test('a file that is not UTF-8 names the file', () {
    // 다른 읽기 실패(부재·권한)와 달리 고칠 곳이 그 설정 파일이다.
    expect(
      () => readProjectConfiguration<void>(
        'dartograph.yaml',
        () => throw const Utf8DecodeException('/somewhere/dartograph.yaml'),
      ),
      throwsA(
        isA<ProjectConfigurationException>().having(
          (error) => error.message,
          'message',
          'invalid dartograph.yaml: the file is not valid UTF-8',
        ),
      ),
    );
  });

  test('read boundary rejections keep their own type', () {
    // 장치·FIFO·상한 초과는 설정 내용이 아니라 입력 자체의 문제다. CLI가 원인대로
    // 진단하도록 감싸지 않는다.
    const rejection = NonRegularFileException();
    expect(
      () => readProjectConfiguration<void>(
        'dartograph.yaml',
        () => throw rejection,
      ),
      throwsA(same(rejection)),
    );
  });

  test('an already attributed failure is not prefixed twice', () {
    const failure = ProjectConfigurationException(
      '--workspace requires a pub workspace root',
    );
    expect(
      () => readProjectConfiguration<void>('pubspec.yaml', () => throw failure),
      throwsA(same(failure)),
    );
  });

  test('failures that are not format errors pass through unchanged', () {
    const failure = PathNotFoundException('x', OSError('No such file', 2));
    expect(
      () => readProjectConfiguration<void>(
        'dartograph.yaml',
        () => throw failure,
      ),
      throwsA(same(failure)),
    );
  });

  test('the result of a successful read is returned as is', () {
    expect(readProjectConfiguration('dartograph.yaml', () => 42), 42);
  });
}

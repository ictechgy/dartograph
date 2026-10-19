import 'package:dartograph/src/analysis/dependency_audit.dart';
import 'package:dartograph/src/export/dead_reporter.dart';
import 'package:dartograph/src/export/dependency_reporter.dart';
import 'package:test/test.dart';

import '../support/markdown_fixture_support.dart';

void main() {
  test('markdown limitations stay inert text', () {
    // workspace 멤버 문자열처럼 저장소가 정한 limitation이 PR 코멘트에서
    // 링크·이미지·HTML·code span·멘션으로 렌더링되지 않는다.
    final markdown = DependencyReporter.render(
      ReportFormat.markdown,
      const [
        DependencyFinding(
          name: 'collection',
          kind: 'unused-dependency',
          reason: 'declared in dependencies but no package: import',
        ),
      ],
      limitations: const [hostileMarkdownText],
    );

    expect(markdown, contains('\n- $escapedMarkdownText\n'));
    // 정상 finding 행의 바이트는 그대로다.
    expect(
      markdown,
      contains(
        '| warning | unused-dependency | `collection` | '
        'declared in dependencies but no package: import | — |',
      ),
    );
  });
}

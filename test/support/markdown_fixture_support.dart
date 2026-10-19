/// 저장소가 정한 문자열이 Markdown 리포트의 자유 문구로 실릴 때의 공격 입력이다.
///
/// dartograph.yaml 미지 키·build.yaml 값·런타임 리터럴처럼 limitation·detail·
/// evidence에 원문으로 들어가는 값을 흉내 낸다. 인라인 링크·이미지·raw HTML·
/// HTML 주석·멘션·엔티티(`&#64;`는 렌더링 뒤 `@`가 된다)·code span·이스케이프된
/// 백틱·표 파이프·제어문자(ESC)를 한 줄에 섞는다.
const hostileMarkdownText =
    'keys: [Approve](https://evil.example) '
    '![p](https://evil.example/p.png) '
    '<img src="https://evil.example/t.png"> <!-- hidden --> '
    '@org/team &#64;victim `tick` \\`esc` | pipe \x1b[31m';

/// [hostileMarkdownText]를 Markdown 자유 문구로 이스케이프한 기대값이다(손으로 확인).
///
/// `]` 바로 뒤 `(`·`<`·`&`·백틱·역슬래시·파이프는 백슬래시로 이스케이프되고,
/// 영숫자 앞 `@` 뒤에는 `&#8203;`이 들어간다. `[`·`!`와 제어문자의 가시
/// 이스케이프(`\x1b`)는 그대로다. 링크 문법이 깨진 뒤 남는 맨 URL
/// (`https://evil.example`)은 GFM에서 여전히 자동 링크가 된다. 글자가 곧 주소라
/// 목적지를 숨기지 못한다(`ReportEscapes.mdText`의 경계).
const escapedMarkdownText =
    r'keys: [Approve]\(https://evil.example) '
    r'![p]\(https://evil.example/p.png) '
    r'\<img src="https://evil.example/t.png"> \<!-- hidden --> '
    r'@&#8203;org/team \&#64;victim \`tick\` \\\`esc\` \| pipe \x1b[31m';

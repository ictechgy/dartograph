# pub.dev verified publisher 설정

공식 절차·설정 완료 확인일: 2026-09-22.

## 현재 상태

2026-09-22 [coden.kr publisher](https://pub.dev/publishers/coden.kr)를 생성하고
두 패키지의 이전을 완료했다. 공개 API 응답과 각 패키지 페이지의
verified publisher 배지를 확인했다.

| 패키지 | 인증 완료 당시 버전 | 공개 API의 `publisherId` |
|---|---|---|
| [dartograph](https://pub.dev/packages/dartograph) | 0.15.0 | `coden.kr` |
| [dartograph_analysis_plugin](https://pub.dev/packages/dartograph_analysis_plugin) | 0.1.0 | `coden.kr` |

Google Search Console에서 `coden.kr`의 **Domain property** 소유권을 확인했다.
Cloudflare의 기존 CNAME 두 개는 보존하고 Google 인증 TXT 레코드 한 개만 추가했다.
인증 상태를 유지하기 위해 해당 TXT 레코드는 삭제하지 않는다.
사용자가 승인한 로그인 계정 이메일을 publisher의 공개 연락처로 사용했으며,
이메일 주소와 인증 값은 이 문서에 기록하지 않는다.

이 설정은 pub.dev의 계정·패키지 관리 작업이다. `pubspec.yaml`의
homepage 변경이나 같은 버전의 재게시로 처리하지 않는다. publisher 설정 자체에서는 새 버전을 발행하지 않았다.

## 설정 절차 참고

현재 두 패키지는 설정이 끝났으므로 아래 절차를 반복하지 않는다.

1. 사용할 도메인을 정하고 Google Search Console에서 **Domain property**의
   소유권을 확인한다. URL-prefix property의 HTML 파일 인증으로 대신하지 않는다.
   DNS 확인이 필요하면 Search Console이 안내한 레코드를 기존 DNS를 보존하며 추가한다.
2. pub.dev에 로그인한 뒤 사용자 메뉴의 **Create Publisher**에서 그 도메인을
   입력한다. Search Console 인증이 완료된 뒤 생성 절차를 다시 진행한다.
3. publisher 관리자 권한과 `dartograph` 업로더 권한이 있는 계정으로
   [패키지 Admin](https://pub.dev/packages/dartograph/admin)을 연다.
   대상 도메인을 확인하고 **Transfer to Publisher**로 이전한다.
4. 패키지 페이지의 publisher 도메인·배지와 공개 API의 `publisherId`를 확인한다.
   `dartograph_analysis_plugin`도 이전할 경우 별도 패키지 Admin에서 같은 검증을 한다.

패키지를 publisher로 이전하면 개인 업로더 계정으로 되돌릴 수 없다.
실제 이전 전 대상 도메인과 패키지 범위를 확인한다. 인증 과정에서 비밀번호·
인증코드·쿠키·토큰을 문서나 실행 원장에 저장하지 않는다.

## 확인 근거

- [Dart: verified publishers](https://dart.dev/tools/pub/verified-publishers)
  — 도메인과 Search Console Domain property 관리자 권한을 통한 확인.
- [Dart: publisher 생성](https://dart.dev/tools/pub/publishing#create-a-verified-publisher)
  및 [패키지 이전](https://dart.dev/tools/pub/publishing#transfer-a-package-to-a-verified-publisher)
  — 생성 절차·필요 권한·개인 계정으로의 복귀 제한.
- [Google: 사이트 소유권 확인](https://support.google.com/webmasters/answer/9008080)
  — Domain property의 DNS 인증과 기존 소유자 확인 레코드 보존.
- 공개 상태 조회: [dartograph publisher](https://pub.dev/api/packages/dartograph/publisher),
  [analysis plugin publisher](https://pub.dev/api/packages/dartograph_analysis_plugin/publisher).

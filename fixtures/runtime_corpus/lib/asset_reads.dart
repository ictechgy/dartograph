// Flutter SDK 없이 분석하므로 import가 해석되지 않는다. 탐지기는 이때 이름으로
// 폴백하며, 그 동작이 이 fixture의 검증 대상이다.
// ignore_for_file: non_type_as_type_argument, undefined_class, undefined_function, undefined_identifier, uri_does_not_exist

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 번들 에셋 읽기(선언되어 있고 파일도 있다).
Future<ByteData> corpusAsset() => rootBundle.load('assets/bundled.json');

/// 번들 문자열 읽기: 의도된 미충족 입력이다.
Future<String> corpusMissingAsset() =>
    rootBundle.loadString('assets/missing.json');

/// 위젯 에셋(명명 생성자 형태).
Image corpusImage() => Image.asset('assets/bundled.json');

/// 페인팅 에셋.
AssetImage corpusAssetImage() => AssetImage('assets/bundled.json');

/// 다른 패키지의 에셋: Flutter 도구가 해석하므로 미판정으로 남는다.
AssetImage corpusPackageAsset() =>
    AssetImage('packages/other/logo.json', package: 'other');

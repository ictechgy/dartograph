import 'dart:io';

/// 존재하는 설정 파일.
File corpusSettings() => File('config/runtime.yaml');

/// 존재하지 않는 설정 파일: 의도된 미충족 입력이다.
File corpusMissingSettings() => File('config/missing.yaml');

/// 존재하는 설정 디렉터리.
Directory corpusConfigDirectory() => Directory('config/');

/// 계산된 경로: 리터럴이 아니라 미판정으로 남는다.
File corpusComputed(String path) => File(path);

/// 설정으로 보지 않는 단일 세그먼트 경로(오탐 방지 확인용).
File corpusOutput() => File('output.csv');

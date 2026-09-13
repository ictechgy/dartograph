import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:mirrors';

/// 다른 Dart 프로그램을 URI로 띄운다(파일이 있어 충족으로 판정된다).
Future<Isolate> corpusSpawnUri() =>
    Isolate.spawnUri(Uri.parse('bin/corpus_worker.dart'), const [], null);

/// in-process 진입점을 띄운다. 대상 코드는 정적으로 확정되지 않는다.
Future<Isolate> corpusSpawn(void Function(Null) entry) =>
    Isolate.spawn(entry, null);

/// 외부 실행 파일 호출: PATH에서 찾으면 충족이다.
Future<ProcessResult> corpusRun() => Process.run('git', const ['--version']);

/// 동기 외부 실행 파일 호출.
ProcessResult corpusRunSync() => Process.runSync('git', const ['--version']);

/// 동기적으로 띄우는 프로세스.
Future<Process> corpusStart() => Process.start('git', const ['--version']);

/// 맨 이름 네이티브 라이브러리: OS 로더가 루트 밖에서 찾으므로 미판정이다.
DynamicLibrary corpusLibrary() => DynamicLibrary.open('libcorpus.so');

/// 경로로 지정한 네이티브 라이브러리: 루트 기준으로 존재를 확인한다.
DynamicLibrary corpusLibraryPath() =>
    DynamicLibrary.open('assets/libcorpus.so');

/// 계산된 이름의 호출.
Object? corpusApply(Object? Function() callee) =>
    Function.apply(callee, const []);

/// 계산된 URI.
Uri corpusUri(String raw) => Uri.parse(raw);

/// 리플렉션: 정적 참조 없이 코드에 닿을 수 있다.
ClassMirror corpusMirror(Object target) => reflectClass(target.runtimeType);

/// 런타임 전용 의존성의 종류다.
///
/// 정적 import 그래프가 잡지 못하는, 실행 시점에만 드러나는 입력을 나눈다.
/// 선언 순서가 보고서의 카테고리 순서이며 text·markdown·JSON에서 고정이다.
enum RuntimeFactKind {
  /// 환경변수·dart-define 읽기다.
  env('env'),

  /// 코드·라이브러리·프로세스를 간접 참조로 여는 호출이다.
  dynamicLoad('dynamicLoad'),

  /// 설정 파일·경로 의존성이다.
  config('config'),

  /// 번들 에셋이다.
  asset('asset'),

  /// 네트워크 등 외부 자원이다.
  external('external');

  const RuntimeFactKind(this.key);

  /// 보고서에서 쓰는 안정적인 키다(enum 이름 변경에 영향받지 않는다).
  final String key;
}

/// 사실이 어느 입력 채널로 충족되는지 나타낸다.
///
/// 같은 이름이라도 dart-define과 프로세스 환경변수는 서로를 충족하지 않으므로,
/// 검증기는 이 채널로 제공 입력을 고른다. 보고서의 `detail`과 `evidence`가 같은
/// 구분을 사람에게도 드러낸다.
enum RuntimeFactChannel {
  /// `String.fromEnvironment` 계열 컴파일 타임 선언이다.
  dartDefine('dart-define'),

  /// `Platform.environment` 프로세스 환경이다.
  processEnvironment('environment'),

  /// `File` 등 파일 경로다.
  filePath('file'),

  /// `Directory` 등 디렉터리 경로다.
  directoryPath('directory'),

  /// 번들 에셋 경로다.
  assetBundle('asset'),

  /// PATH에서 찾는 실행 파일이다.
  executable('executable'),

  /// `DynamicLibrary.open`의 네이티브 라이브러리다.
  nativeLibrary('native-library'),

  /// 로드할 다른 Dart 프로그램의 URI다.
  uri('uri'),

  /// 리플렉션·함수 참조처럼 정적으로 이름이 확정되지 않는 대상이다.
  reflection('reflection'),

  /// 네트워크로 향하는 URL이다.
  externalUrl('external-url');

  const RuntimeFactChannel(this.key);

  /// 보고서에서 쓰는 안정적인 키다.
  final String key;
}

/// 리터럴이 아니라 계산된 이름을 가진 사실의 표시 이름이다.
const runtimeComputedName = '<computed>';

/// 런타임 의존성 탐지 사실 하나다.
///
/// [id]를 뺀 모든 필드는 감지한 소스 위치에 대한 관측이다. 정렬은
/// [compareFacts]가 종류→소스→위치→이름 순으로 결정한다.
final class RuntimeFact {
  /// 탐지 사실을 만든다. [path]는 검증할 후보 경로(패키지 루트 기준 또는 절대),
  /// [defaultValue]는 `fromEnvironment`의 명시적 기본값이다.
  /// [unverifiableReason]이 있으면 탐지 단계에서 이미 판정 불가로 분류된 사실이다.
  const RuntimeFact({
    required this.kind,
    required this.channel,
    required this.name,
    required this.source,
    required this.line,
    required this.column,
    required this.detail,
    this.path,
    this.defaultValue,
    this.literal = true,
    this.unverifiableReason,
  });

  /// 탐지 카테고리다.
  final RuntimeFactKind kind;

  /// 충족 채널이다.
  final RuntimeFactChannel channel;

  /// 환경변수 이름·경로·URL·대상 이름이다. 리터럴이 아니면
  /// [runtimeComputedName]이다.
  final String name;

  /// `project:상대경로` 소스 ID 또는 프로젝트 밖 절대 파일 URI다.
  final String source;

  /// 소스에서 1부터 세는 줄 번호다.
  final int line;

  /// 소스에서 1부터 세는 열 번호다.
  final int column;

  /// 사람이 읽는 관측 문맥이다(어떤 API로 읽혔는지).
  final String detail;

  /// 존재를 확인할 후보 경로다. 절대 경로면 그대로, 아니면 패키지 루트 기준이다.
  final String? path;

  /// `fromEnvironment`의 명시적 기본값이다. 없으면 null이다.
  final String? defaultValue;

  /// 대상이 소스 리터럴인지 여부다. false면 정적으로 판정할 수 없다.
  final bool literal;

  /// 탐지 단계에서 이미 판정 불가로 분류된 이유다. 있으면 검증기는 이 사유를
  /// 그대로 `unverified`에 싣고 존재 검사를 시도하지 않는다.
  final String? unverifiableReason;

  /// 위치와 이름으로 만든 안정적인 식별자다.
  String get id => '${kind.key}:$name@$source:$line:$column';

  /// 보고서 JSON 표현이다. 키는 사전순으로 고정한다.
  ///
  /// [unverifiableReason]이 있으면 함께 실어, 탐지 단계의 판정 불가 사유가
  /// 검증 결과(`unverified`)에만 숨지 않고 사실 자체에도 남게 한다.
  Map<String, Object> toJson() => {
    'channel': channel.key,
    'column': column,
    'detail': detail,
    'id': id,
    'kind': kind.key,
    'line': line,
    'name': name,
    'source': source,
    'unverifiableReason': ?unverifiableReason,
  };
}

/// 사실을 종류→소스→줄→열→이름 순으로 정렬한다.
///
/// 같은 입력은 언제나 같은 순서를 내야 하므로 그래프·소스 순회 순서에 기대지
/// 않고 위치로 정렬한다.
int compareRuntimeFacts(RuntimeFact a, RuntimeFact b) {
  final byKind = a.kind.index.compareTo(b.kind.index);
  if (byKind != 0) return byKind;
  final bySource = a.source.compareTo(b.source);
  if (bySource != 0) return bySource;
  final byLine = a.line.compareTo(b.line);
  if (byLine != 0) return byLine;
  final byColumn = a.column.compareTo(b.column);
  if (byColumn != 0) return byColumn;
  final byName = a.name.compareTo(b.name);
  if (byName != 0) return byName;
  return a.channel.index.compareTo(b.channel.index);
}

/// 검증에 쓰는 입력이다.
///
/// `--env`·`--dart-define`이 하나라도 주어지면 그 집합만 쓴다(hermetic). 주어지지
/// 않은 채널만 실제 프로세스 값으로 채우므로, CI가 준 입력과 우연한 셸 환경이
/// 섞이지 않는다.
final class RuntimeInputs {
  /// 검증 입력을 만든다.
  const RuntimeInputs({
    this.environment = const {},
    this.dartDefines = const {},
    this.environmentFromProcess = true,
    this.windows = false,
  });

  /// 유효 환경변수다(키 정렬은 호출자가 보장하지 않아도 된다).
  final Map<String, String> environment;

  /// 유효 dart-define이다.
  final Map<String, String> dartDefines;

  /// [environment]가 실제 프로세스 환경인지 여부다(근거 문구에 쓴다).
  final bool environmentFromProcess;

  /// Windows 경로·확장자 규칙을 쓸지 여부다.
  final bool windows;
}

/// 파일 시스템에 묻는 최소 질문이다.
///
/// 검증기는 이 경계를 통해서만 파일을 관측하므로, 규칙은 순수 함수로 남고
/// 테스트는 가짜 구현을 주입한다.
abstract interface class RuntimeFileSystem {
  /// [path]의 종류를 돌려준다. 상대 경로는 패키지 루트 기준으로 해석한다.
  RuntimePathState state(String path);

  /// [path]가 실행 가능한 파일인지 확인한다.
  bool executableAt(String path);
}

/// 경로 하나에 대한 파일 시스템 관측이다.
enum RuntimePathState {
  /// 일반 파일이 있다.
  file,

  /// 디렉터리가 있다.
  directory,

  /// 아무것도 없다.
  missing,
}

/// `--execute`가 남긴 실행 증거다.
final class RuntimeExecution {
  /// 실행 결과를 만든다. [exitCode]는 타임아웃으로 죽은 경우 신호 번호(음수)다.
  const RuntimeExecution({
    required this.entrypoint,
    required this.exitCode,
    required this.timedOut,
    required this.stderrSummary,
  }) : unresolvedReason = null;

  /// dart 실행 파일을 해석하지 못해 실행하지 못한 결과를 만든다.
  ///
  /// 실행 자체가 없었으므로 종료 코드도 stderr도 없다. 사유만 남겨 "실행했다"는
  /// 증거와 구분한다.
  const RuntimeExecution.unresolved({
    required this.entrypoint,
    required String reason,
  }) : exitCode = null,
       timedOut = false,
       stderrSummary = '',
       unresolvedReason = reason;

  /// 실행한 진입점이다.
  final String entrypoint;

  /// 자식 프로세스의 종료 코드다. 실행하지 못했으면 null이다.
  final int? exitCode;

  /// 제한 시간을 넘겨 종료시켰는지 여부다.
  final bool timedOut;

  /// 실패 진단의 요약이다(제어문자는 이스케이프된다).
  final String stderrSummary;

  /// 실행하지 못한 사유다. 실행했으면 null이다.
  final String? unresolvedReason;

  /// 실행하지 못해 판정 불가인지 여부다.
  bool get unresolved => unresolvedReason != null;

  /// 성공적으로 끝났는지 여부다. 실행하지 못한 경우는 성공이 아니다.
  bool get ok => !unresolved && exitCode == 0 && !timedOut;

  /// 보고서 JSON 표현이다. 키는 사전순으로 고정한다.
  ///
  /// 실행하지 못한 경우 `exitCode`는 null이고 `reason`이 붙는다 — 종료 코드가
  /// 없는 것과 0인 것을 같은 표기로 뭉개지 않는다.
  Map<String, Object?> toJson() => {
    'entrypoint': entrypoint,
    'exitCode': exitCode,
    'ok': ok,
    'reason': ?unresolvedReason,
    'stderrSummary': stderrSummary,
    'timedOut': timedOut,
  };
}

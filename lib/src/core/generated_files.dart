/// 코드 생성기가 쓰는 Dart 파일 접미사의 단일 목록이다.
///
/// 그래프(보존 루트·synthesized 정점·dup 토큰 제외), HTTP route 사실, `anon`
/// 익명화의 확장자 보존이 같은 목록을 쓴다. 외부 의존이 없어 core에 둔다. 사본이 있으면 한쪽에만 생성기가 더해져 같은 파일이 명령에 따라
/// 생성 코드이기도 하고 아니기도 했다. 사람이 쓴 파일과 이름이 겹치기 쉬운 접미사
/// (예: injectable의 `.config.dart`)는 넣지 않는다 — 손으로 쓴 선언을 생성 코드로
/// 보존하면 미사용이 가려진다. 그런 생성기의 출력은 `dartograph.yaml`의
/// `retained_files`로 보존한다.
library;

/// 생성 파일로 보는 접미사다.
///
/// json_serializable·riverpod 등 build_runner(`.g.dart`), freezed, chopper,
/// auto_route(`.gr.dart`), mockito(`.mocks.dart`), dart_mappable(`.mapper.dart`),
/// flutter_gen(`.gen.dart`), protobuf(`.pb*.dart`)의 출력이다.
const generatedDartSuffixes = {
  '.g.dart',
  '.freezed.dart',
  '.chopper.dart',
  '.gr.dart',
  '.mocks.dart',
  '.mapper.dart',
  '.gen.dart',
  '.pb.dart',
  '.pbenum.dart',
  '.pbgrpc.dart',
  '.pbjson.dart',
  '.pbserver.dart',
};

/// [path]가 [generatedDartSuffixes] 중 하나로 끝나는지 본다.
bool isGeneratedDartPath(String path) =>
    generatedDartSuffixes.any(path.endsWith);
